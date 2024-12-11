module XenAPI = Client.Client

let rpc xml =
  let open Xmlrpc_client in
  XMLRPC_protocol.rpc ~srcstr:"daily-license-check" ~dststr:"xapi"
    ~transport:(Unix "/var/xapi/xapi")
    ~http:(xmlrpc ~version:"1.0" "/")
    xml

let _ =
  let session_id =
    XenAPI.Session.login_with_password ~rpc ~uname:"" ~pwd:"" ~version:"1.0"
      ~originator:"daily-license-check"
  in
  Xapi_stdext_pervasives.Pervasiveext.finally
    (fun () ->
      let now = Xapi_stdext_date.Date.now () in
      let pool, pool_license_state, all_license_params =
        Daily_license_check.get_info_from_db rpc session_id
      in
      let result =
        Daily_license_check.check_license now pool_license_state
          all_license_params
      in
      Daily_license_check.execute rpc session_id pool result
    )
    (fun () -> XenAPI.Session.logout ~rpc ~session_id)
