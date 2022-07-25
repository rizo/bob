open Stdbob
open Prgrss

let choose = function
  | true -> fun _identity -> Fiber.return `Accept
  | false ->
      let open Fiber in
      fun identity ->
        let rec asking () =
          Fiber.getline Unix.stdin >>| Stdlib.Option.map String.lowercase_ascii
          >>= function
          | Some ("y" | "yes" | "") | None -> Fiber.return `Accept
          | Some ("n" | "no") -> Fiber.return `Refuse
          | _ ->
              Fmt.pr "Invalid response, accept from %s [Y/n]: %!" identity;
              asking ()
        in
        Fmt.pr "Accept from %s [Y/n]: %!" identity;
        asking ()

let ask_password () =
  let open Fiber in
  let rec asking () =
    Fiber.getline Unix.stdin >>= function
    | None | Some "" ->
        Fmt.pr "You must insert a password: %!";
        asking ()
    | Some password -> Fiber.return password
  in
  Fmt.pr "Your password: %!";
  asking ()

let source_with_reporter quiet ~config ~identity ~ciphers ~shared_keys sockaddr
    : (Stdbob.bigstring Stream.source, _) result Fiber.t =
  with_reporter ~config quiet incoming_data @@ fun (reporter, finalise) ->
  Transfer.receive
    ~reporter:(Fiber.return <.> reporter)
    ~finalise ~identity ~ciphers ~shared_keys sockaddr

let make_window bits = De.make_window ~bits

let map (fd, st) ~pos len =
  let len = min (Int64.sub st.Unix.LargeFile.st_size pos) (Int64.of_int len) in
  let len = Int64.to_int len in
  let res =
    Unix.map_file fd ~pos Bigarray.char Bigarray.c_layout false [| len |]
  in
  Bigarray.array1_of_genarray res

let collect_and_verify_with_reporter quiet ~config entry path decoder ~src ~off
    leftover =
  let open Fiber in
  let open Stream in
  let from =
    match leftover with
    | Some leftover when Bigarray.Array1.dim src - off > 0 ->
        Source.prepend Bigarray.Array1.(sub src off (dim src - off)) leftover
    | Some leftover -> leftover
    | None -> Source.array [||]
  in
  let offset = Bigarray.Array1.dim src - off in
  let offset = Int64.neg (Int64.of_int offset) in
  Logs.debug (fun m -> m "Start to re-analyzed the rest of the PACK file.");
  Stream.run ~from
    ~via:Flow.(save_into ~offset path << Pack.analyse ?decoder ignore)
    ~into:Sink.list
  >>= fun (entries, source) ->
  Logs.debug (fun m -> m "All objects are analyzed.");
  Fiber.Option.iter Source.dispose source >>= fun () ->
  let[@warning "-8"] entries, _hash =
    List.partition (function `Elt _, _, _, _ -> true | _ -> false) entries
  in
  let entries =
    List.map (function `Elt elt, _, _, _ -> elt | _ -> assert false) entries
  in
  let total =
    let acc =
      match entry with _, _, `Base _ -> 0 | _, _, (`Ofs _ | `Ref _) -> 1
    in
    List.fold_left
      (fun count -> function
        | _, _, (`Ofs _ | `Ref _) -> succ count
        | _, _, `Base _ -> count)
      acc entries
  in
  let entries = Source.list (entry :: entries) in
  Pack.collect entries >>= fun (status, oracle) ->
  Logs.debug (fun m -> m "All objects are collected.");
  with_reporter ~config quiet (make_verify_bar ~total)
  @@ fun (reporter, finalise) ->
  Pack.verify ~reporter:(reporter <.> Stdbob.always 1) ~oracle path status
  >>= fun () ->
  Logs.debug (fun m -> m "All objects are verified.");
  finalise ();
  Fiber.return status

let unpack_with_reporter quiet ~config ~total pack name hash =
  let open Fiber in
  with_reporter ~config quiet (make_extract_bar ~total)
  @@ fun (reporter, finalise) ->
  reporter 2;
  (* XXX(dinosaure): report the commit and the root directory. *)
  Pack.create_directory ~reporter pack (Bob_fpath.v name) hash >>= fun _ ->
  finalise ();
  Fiber.return (Ok ())

let extract_with_reporter quiet ~config ?g
    (from : Stdbob.bigstring Stream.source) =
  let open Fiber in
  let open Stream in
  let tmp = Temp.random_temporary_path ?g "pack-%s.pack" in
  let via = Flow.(save_into tmp << Pack.analyse ignore) in
  Stream.run ~from ~via ~into:Sink.first >>= function
  | Some (`End _, _, _, _), _ | None, _ -> Fiber.return (Error `Empty_pack_file)
  | ( Some (`Elt (offset, _status, `Base (`D, _weight)), _decoder, src, off),
      leftover ) ->
      Stream.run ~from:(Source.file ~offset tmp)
        ~via:(Pack.inflate_entry ~reporter:Fiber.ignore)
        ~into:Sink.to_string
      >>= fun (name, source) ->
      Fiber.Option.iter Source.dispose source >>= fun () ->
      Fmt.pr ">>> Received a file: %s.\n%!" name;
      let from =
        match leftover with
        | Some leftover when Bigarray.Array1.dim src - off > 0 ->
            Source.prepend
              Bigarray.Array1.(sub src off (dim src - off))
              leftover
        | Some leftover -> leftover
        | None -> Source.array [| src |]
      in
      Stream.run ~from
        ~via:(Pack.inflate_entry ~reporter:Fiber.ignore)
        ~into:(Sink.file (Bob_fpath.v name))
      >>= fun ((), _source) ->
      Fiber.Option.iter Source.dispose source >>= fun () -> Fiber.return (Ok ())
  | Some (`Elt entry, decoder, src, off), leftover ->
      Logs.debug (fun m -> m "Got a directory.");
      collect_and_verify_with_reporter quiet ~config entry tmp decoder ~src ~off
        leftover
      >>= Pack.unpack tmp
      >>? fun (name, total, hash, pack) ->
      Fmt.pr ">>> Received a folder: %s.\n%!" name;
      unpack_with_reporter quiet ~config ~total pack name hash

let run_client quiet g dns addr secure_port password yes =
  let open Fiber in
  (match addr with
  | `Inet (inet_addr, port) ->
      Fiber.return (Ok (Unix.ADDR_INET (inet_addr, port)))
  | `Domain (domain_name, port) -> (
      Bob_dns.gethostbyname6 dns domain_name >>= function
      | Ok ip6 ->
          Fiber.return
            (Ok
               (Unix.ADDR_INET (Ipaddr_unix.to_inet_addr (Ipaddr.V6 ip6), port)))
      | Error _ -> (
          Bob_dns.gethostbyname dns domain_name >>= function
          | Ok ip4 ->
              Fiber.return
                (Ok
                   (Unix.ADDR_INET
                      (Ipaddr_unix.to_inet_addr (Ipaddr.V4 ip4), port)))
          | Error _ as err -> Fiber.return err)))
  >>? fun sockaddr ->
  (match password with
  | Some password -> Fiber.return password
  | None -> ask_password ())
  >>= fun password ->
  let domain = Unix.domain_of_sockaddr sockaddr in
  let socket = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  Fiber.connect socket sockaddr >>| reword_error (fun err -> `Connect err)
  >>? fun () ->
  Logs.debug (fun m -> m "The client is connected to the relay.");
  let choose = choose yes in
  Bob_clear.client socket ~choose ~g ~password
  >>? fun (identity, ciphers, shared_keys) ->
  let config = Progress.Config.v ~ppf:Fmt.stdout () in
  let sockaddr = Transfer.sockaddr_with_secure_port sockaddr secure_port in
  source_with_reporter quiet ~config ~identity ~ciphers ~shared_keys sockaddr
  >>| Transfer.open_error
  >>? extract_with_reporter quiet ~config ~g

let pp_error ppf = function
  | `Blocking_connect err -> Connect.pp_error ppf err
  | #Transfer.error as err -> Transfer.pp_error ppf err
  | #Bob_clear.error as err -> Bob_clear.pp_error ppf err
  | `Empty_pack_file -> Fmt.pf ppf "Empty PACK file"
  | `No_root -> Fmt.pf ppf "The given PACK file has no root"
  | `Msg err -> Fmt.pf ppf "%s." err

let run quiet g () dns addr secure_port password yes =
  match Fiber.run (run_client quiet g dns addr secure_port password yes) with
  | Ok () -> `Ok 0
  | Error err ->
      Fmt.epr "%s: %a.\n%!" Sys.executable_name pp_error err;
      `Ok 1

open Cmdliner
open Args

let password =
  let doc = "The password to share." in
  Arg.(value & pos 0 (some string) None & info [] ~doc ~docv:"<password>")

let term =
  Term.(
    ret
      (const run $ term_setup_logs $ term_setup_random $ term_setup_temp
     $ term_setup_dns $ relay $ secure_port $ password $ yes))

let cmd =
  let doc = "Receive a file from a peer who share the given password." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "$(tname) tries many handshakes with many peers throught the given \
         relay with the given password. Once found, it asks the user if it \
         wants to complete the handshake. Therefore, if the user accepts, we \
         receive the desired file. Otherwise, $(tname) waits for another peer.";
    ]
  in
  Cmd.v (Cmd.info "recv" ~doc ~man) term
