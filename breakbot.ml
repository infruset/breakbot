open Utils
open Common

(* Works only if processing is much faster than the rate at which we
   receive/parse the messages from the exchange. Otherwise processing
   might block the exchanges from updating... It has thus to be the
   case that processing is indeed faster than receiving+parsing *)

let () =
  let config = Config.of_file "breakbot.conf" in
  let mtgox_key, mtgox_secret, mtgox_addr  =
    match (List.assoc "mtgox" config) with
      | [key; secret; addr] ->
        Uuidm.to_bytes (Opt.unbox (Uuidm.of_string key)),
        Cohttp.Base64.decode secret, addr
      | _ -> failwith "Syntax error in config file."
  and btce_key, btce_secret, btce_addr =
    match (List.assoc "btce" config) with
      | [key; secret; addr] -> key, secret, addr
      | _ -> failwith "Syntax error in config file."
  and bs_login, bs_passwd, bs_addr =
    match (List.assoc "bitstamp" config) with
    | [login; passwd; addr] -> login, passwd, addr
    | _ -> failwith "Syntax error in config file."
  in
  let exchanges =
    [(new Mtgox.mtgox mtgox_key mtgox_secret mtgox_addr :> Exchange.exchange);
     (new Btce.btce btce_key btce_secret btce_addr      :> Exchange.exchange);
     (new Bitstamp.bitstamp bs_login bs_passwd bs_addr  :> Exchange.exchange)
    ] in
  let mvars = List.map (fun xch -> xch#get_mvar) exchanges in
  let process mvars =
    let rec process () =
      lwt xch = Lwt.pick (List.map Lwt_mvar.take mvars) in
      let () = Printf.printf "Exchange %s has just been updated!\n"
        xch#name in
      let other_xchs = List.filter (fun x -> x != xch) exchanges in
      let arbiter_one x1 x2 =
        try
          let sign, gain, spr, bpr, pr, am = Books.arbiter_unsafe
            "USD" x1#get_books x2#get_books in
          let real_gain = ((S.to_float spr *. 0.994 -.
                              S.to_float bpr *. 1.006) /. 1e16) in
          Printf.printf "%s\t%s\t%s: %f (%f USD, ratio %f)\n%!"
            x1#name
            (match sign with
              | 1 -> "->"
              | 0 -> "<->"
              | -1 -> "<-"
              | _ -> failwith "") x2#name
            (S.to_face_float am) real_gain
            S.(real_gain /. to_float (pr * am))
        with Not_found -> ()
      in
      let () = List.iter (fun x -> arbiter_one xch x) other_xchs in
      process ()
    in process ()
  in
  let threads_to_run =
    process mvars :: List.map (fun xch -> xch#update) exchanges in
  Lwt.pick threads_to_run |> Lwt_main.run
