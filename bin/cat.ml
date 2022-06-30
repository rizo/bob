let reporter ppf =
  let report src level ~over k msgf =
    let k _ =
      over ();
      k ()
    in
    let with_metadata header _tags k ppf fmt =
      Format.kfprintf k ppf
        ("%a[%a]: " ^^ fmt ^^ "\n%!")
        Logs_fmt.pp_header (level, header)
        Fmt.(styled `Magenta string)
        (Logs.Src.name src)
    in
    msgf @@ fun ?header ?tags fmt -> with_metadata header tags k ppf fmt
  in
  { Logs.report }

let () = Fmt_tty.setup_std_outputs ~style_renderer:`Ansi_tty ~utf_8:true ()
let () = Logs.set_reporter (reporter Fmt.stdout)
let () = Logs.set_level ~all:true (Some Logs.Debug)

open Fiber

let rec full_write fd str off len =
  Fiber.write Unix.stdout ~off ~len str >>= function
  | Error _err -> exit 1
  | Ok len' ->
      if len - len' > 0 then full_write fd str (off + len') (len - len')
      else Fiber.return ()

let rec cat () =
  Fiber.read Unix.stdin >>= function
  | Error _err -> exit 1
  | Ok `End -> Fiber.return ()
  | Ok (`Data str) -> full_write Unix.stdout str 0 (String.length str) >>= cat

let () = Fiber.run (cat ())
