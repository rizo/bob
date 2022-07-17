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
        ~into:(Sink.file (Fpath.v name))
      >>= fun ((), _source) ->
      Fiber.Option.iter Source.dispose source >>= fun () -> Fiber.return (Ok ())
  | Some (`Elt entry, decoder, src, off), leftover -> (
      let from =
        match leftover with
        | Some leftover when Bigarray.Array1.dim src - off > 0 ->
            Source.prepend
              Bigarray.Array1.(sub src off (dim src - off))
              leftover
        | Some leftover -> leftover
        | None -> Source.array [||]
      in
      let offset = Bigarray.Array1.dim src - off in
      let offset = Int64.neg (Int64.of_int offset) in
      Stream.run ~from
        ~via:Flow.(save_into ~offset tmp << Pack.analyse ?decoder ignore)
        ~into:Sink.list
      >>= fun (entries, source) ->
      Fiber.Option.iter Source.dispose source >>= fun () ->
      let[@warning "-8"] entries, _hash =
        List.partition (function `Elt _, _, _, _ -> true | _ -> false) entries
      in
      let entries =
        List.map
          (function `Elt elt, _, _, _ -> elt | _ -> assert false)
          entries
      in
      let total = List.length entries + 1 in
      let entries = Source.list (entry :: entries) in
      Pack.collect entries >>= fun (status, oracle) ->
      with_reporter ~config quiet (make_verify_bar ~total)
      @@ fun (reporter, finalise) ->
      Pack.verify ~reporter:(reporter <.> Stdbob.always 1) ~oracle tmp status
      >>= fun () ->
      finalise ();
      match
        Array.find_opt (fun status -> Pack.kind_of_status status = `A) status
      with
      | None -> Fiber.return (Error `No_root)
      | Some root ->
          let fd =
            Unix.openfile (Fpath.to_string tmp) Unix.[ O_RDONLY ] 0o644
          in
          let st = Unix.LargeFile.stat (Fpath.to_string tmp) in
          let id =
            Array.fold_left
              (fun tbl status ->
                Hashtbl.add tbl
                  (Pack.uid_of_status status)
                  (Pack.offset_of_status status);
                tbl)
              (Hashtbl.create 0x100) status
          in
          let find uid =
            Logs.debug (fun m -> m "Try to find: %a." Digestif.SHA1.pp uid);
            Hashtbl.find id uid
          in
          let pack =
            Carton.Dec.make (fd, st) ~allocate:make_window
              ~z:(De.bigstring_create De.io_buffer_size)
              ~uid_ln:Digestif.SHA1.digest_size
              ~uid_rw:Digestif.SHA1.of_raw_string find
          in
          let root =
            Carton.Dec.weight_of_offset ~map pack ~weight:Carton.Dec.null
              (Pack.offset_of_status root)
            |> fun weight ->
            let raw = Carton.Dec.make_raw ~weight in
            Carton.Dec.of_offset ~map pack raw
              ~cursor:(Pack.offset_of_status root)
          in
          let root =
            bigstring_to_string
              (Bigarray.Array1.sub (Carton.Dec.raw root) 0 (Carton.Dec.len root))
          in
          let[@warning "-8"] (name :: rest) =
            String.split_on_char '\000' root
          in
          let rest = String.concat "\000" rest in
          let hash =
            Digestif.SHA1.of_raw_string
              (String.sub rest 0 Digestif.SHA1.digest_size)
          in
          let total =
            int_of_string
              (String.sub rest Digestif.SHA1.digest_size
                 (String.length rest - Digestif.SHA1.digest_size))
          in
          Fmt.pr ">>> Received a directory: %s\n%!" name;
          with_reporter ~config quiet (make_extract_bar ~total)
          @@ fun (reporter, finalise) ->
          reporter 2;
          (* XXX(dinosaure): the commit and the root directory. *)
          Pack.create_directory ~reporter pack (Fpath.v name) hash >>= fun _ ->
          finalise ();
          Fiber.return (Ok ()))

let run_client quiet g sockaddr secure_port password yes =
  let domain = Unix.domain_of_sockaddr sockaddr in
  let socket = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  let open Fiber in
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
  | #Transfer.error as err -> Transfer.pp_error ppf err
  | #Bob_clear.error as err -> Bob_clear.pp_error ppf err
  | `Empty_pack_file -> Fmt.pf ppf "Empty PACK file"
  | `No_root -> Fmt.pf ppf "The given PACK file has no root"

let run quiet g sockaddr secure_port password yes =
  match Fiber.run (run_client quiet g sockaddr secure_port password yes) with
  | Ok () -> `Ok 0
  | Error err ->
      Fmt.epr "%s: %a.\n%!" Sys.executable_name pp_error err;
      `Ok 1

open Cmdliner
open Args

let relay =
  let doc = "The IP address of the relay." in
  Arg.(
    value
    & opt (addr_inet ~default:9000) Unix.(ADDR_INET (inet_addr_loopback, 9000))
    & info [ "r"; "relay" ] ~doc ~docv:"<addr>:<port>")

let password =
  let doc = "The password to share." in
  Arg.(required & pos 0 (some string) None & info [] ~doc ~docv:"<password>")

let yes =
  let doc = "Answer yes to all bob questions without prompting." in
  Arg.(value & flag & info [ "y"; "yes" ] ~doc)

let term =
  Term.(
    ret
      (const run $ setup_logs $ setup_random $ relay $ secure_port $ password
     $ yes))

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
