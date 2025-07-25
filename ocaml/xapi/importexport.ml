(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(** Common definitions and functions shared between the import and export code.
 * @group Import and Export
*)

(** Represents a database record (the reference gets converted to a small string) *)
type obj = {cls: string [@key "class"]; id: string; snapshot: Rpc.t}
[@@deriving rpc]

(** Version information attached to each export and checked on import *)
type version = {
    hostname: string
  ; date: string
  ; product_version: string
  ; product_brand: string
  ; build_number: string
  ; xapi_vsn_major: int
  ; xapi_vsn_minor: int
  ; export_vsn: int
        (* 0 if missing, indicates eg whether to expect sha1sums in the stream *)
}

let rpc_of_version x =
  let open Xapi_globs in
  Rpc.Dict
    [
      (_hostname, Rpc.String x.hostname)
    ; (_date, Rpc.String x.date)
    ; (_product_version, Rpc.String x.product_version)
    ; (_product_brand, Rpc.String x.product_brand)
    ; (_build_number, Rpc.String x.build_number)
    ; (_xapi_major, Rpc.Int (Int64.of_int Xapi_version.xapi_version_major))
    ; (_xapi_minor, Rpc.Int (Int64.of_int Xapi_version.xapi_version_minor))
    ; (_export_vsn, Rpc.Int (Int64.of_int Xapi_globs.export_vsn))
    ]

(* manually define a type for VTPM that includes its content. We
   deliberately only capture the essence to facilitate moving to a
   different backend at a later point rather than preserving the entire
   structure. *)

type vtpm' = {
    vTPM'_VM: API.ref_VM
  ; vTPM'_uuid: string
  ; vTPM'_is_unique: bool
  ; vTPM'_is_protected: bool
  ; vTPM'_content: string
}
[@@deriving rpc]

exception Failure of string

let find kvpairs where x =
  if not (List.mem_assoc x kvpairs) then
    raise (Failure (Printf.sprintf "Failed to find key '%s' in %s" x where))
  else
    List.assoc x kvpairs

[@@@warning "-8"]

let version_of_rpc = function
  | Rpc.Dict map ->
      let find = find map "version data" in
      let open Xapi_globs in
      {
        hostname= Rpc.string_of_rpc (find _hostname)
      ; date= Rpc.string_of_rpc (find _date)
      ; product_version= Rpc.string_of_rpc (find _product_version)
      ; product_brand= Rpc.string_of_rpc (find _product_brand)
      ; build_number= Rpc.string_of_rpc (find _build_number)
      ; xapi_vsn_major= Rpc.int_of_rpc (find _xapi_major)
      ; xapi_vsn_minor= Rpc.int_of_rpc (find _xapi_minor)
      ; export_vsn= (try Rpc.int_of_rpc (find _export_vsn) with _ -> 0)
      }
  | rpc ->
      raise
        (Failure
           (Printf.sprintf "version_of_rpc: malformed RPC %s" (Rpc.to_string rpc)
           )
        )

[@@@warning "+8"]

(** An exported VM has a header record: *)
type header = {version: version; objects: obj list} [@@deriving rpc]

exception Version_mismatch of string

module D = Debug.Make (struct let name = "importexport" end)

open D

(** Return a version struct corresponding to this host *)
let this_version __context =
  let host = Helpers.get_localhost ~__context in
  let (_ : API.host_t) = Db.Host.get_record ~__context ~self:host in
  {
    hostname= Xapi_version.hostname
  ; date= Xapi_version.date
  ; product_version= Xapi_version.product_version ()
  ; product_brand= Xapi_version.product_brand ()
  ; build_number= Xapi_version.build_number ()
  ; xapi_vsn_major= Xapi_version.xapi_version_major
  ; xapi_vsn_minor= Xapi_version.xapi_version_minor
  ; export_vsn= Xapi_globs.export_vsn
  }

(** Raises an exception if a prospective import cannot be handled by this code.
    This will get complicated over time... *)
let assert_compatible ~__context other_version =
  let this_version = this_version __context in
  (* error if this host has a lower vsn than the import *)
  if
    this_version.xapi_vsn_major < other_version.xapi_vsn_major
    || this_version.xapi_vsn_major = other_version.xapi_vsn_major
       && this_version.xapi_vsn_minor < other_version.xapi_vsn_minor
  then (
    error
      "Import version is incompatible - this_version=(%d,%d), \
       other_version=(%d,%d)"
      this_version.xapi_vsn_major this_version.xapi_vsn_minor
      other_version.xapi_vsn_major other_version.xapi_vsn_minor ;
    raise (Api_errors.Server_error (Api_errors.import_incompatible_version, []))
  )

let vm_has_field ~(x : obj) ~name =
  match x.snapshot with
  | Rpc.Dict map ->
      List.mem_assoc name map
  | rpc ->
      raise
        (Failure
           (Printf.sprintf "vm_has_field: invalid object %s"
              (Xmlrpc.to_string rpc)
           )
        )

(* This function returns true when the VM record was created pre-ballooning. *)
let vm_exported_pre_dmc (x : obj) =
  (* The VM.parent field was added in rel_midnight_ride, at the same time as ballooning.
     XXX: Replace this with something specific to the ballooning feature if possible. *)
  not (vm_has_field ~x ~name:"parent")

open Client

(** HTTP header type used for streaming binary data *)
let content_type = Http.Hdr.content_type ^ ": application/octet-stream"

let checksum_table_of_rpc = API.string_to_string_map_of_rpc

let compare_checksums a b =
  let success = ref true in
  List.iter
    (fun (filename, csum) ->
      if List.mem_assoc filename b then
        let expected = List.assoc filename b in
        if csum <> expected then (
          error "File %s checksum mismatch (%s <> %s)" filename csum expected ;
          success := false
        ) else
          debug "File %s checksum ok (%s = %s)" filename csum expected
      else (
        error "Missing checksum for file %s (expected %s)" filename csum ;
        success := false
      )
    )
    a ;
  !success

let get_default_sr rpc session_id =
  let pool = List.hd (Client.Pool.get_all ~rpc ~session_id) in
  let sr = Client.Pool.get_default_SR ~rpc ~session_id ~self:pool in
  try
    ignore (Client.SR.get_uuid ~rpc ~session_id ~self:sr) ;
    sr
  with _ ->
    raise
      (Api_errors.Server_error
         (Api_errors.default_sr_not_found, [Ref.string_of sr])
      )

(** Check that the SR is visible on the specified host *)
let check_sr_availability_host ~__context sr host =
  try
    ignore
      (Xapi_vm_helpers.assert_can_see_specified_SRs ~__context ~reqd_srs:[sr]
         ~host
      ) ;
    true
  with _ -> false

let check_sr_availability ~__context sr =
  let localhost = Helpers.get_localhost ~__context in
  check_sr_availability_host ~__context sr localhost

let find_host_for_sr ~__context ?(prefer_slaves = false) sr =
  let choose_fn ~host =
    Xapi_vm_helpers.assert_can_see_specified_SRs ~__context ~reqd_srs:[sr] ~host
  in
  Xapi_vm_helpers.choose_host ~__context ~choose_fn ~prefer_slaves ()

let check_vm_host_SRs ~__context vm host =
  try
    Xapi_vm_helpers.assert_can_see_SRs ~__context ~self:vm ~host ;
    Xapi_vm_helpers.assert_host_is_live ~__context ~host ;
    true
  with _ -> false

let find_host_for_VM ~__context vm =
  Xapi_vm_helpers.choose_host ~__context ~vm
    ~choose_fn:(Xapi_vm_helpers.assert_can_see_SRs ~__context ~self:vm)
    ()

(* On any import error, we try to cleanup the bits we have created *)
type cleanup_stack =
  (Context.t -> (Rpc.call -> Rpc.response) -> API.ref_session -> unit) list

let cleanup (x : cleanup_stack) =
  (* Always perform the cleanup with a fresh login + context to prevent problems with
     any user-supplied one being invalidated *)
  Server_helpers.exec_with_new_task "VM.import (cleanup)" ~task_in_database:true
    (fun __context ->
      Helpers.call_api_functions ~__context (fun rpc session_id ->
          List.iter
            (fun action ->
              Helpers.log_exn_continue "executing cleanup action"
                (action __context rpc) session_id
            )
            x
      )
  )

open Xapi_stdext_pervasives.Pervasiveext

type vm_export_import = {
    vm: API.ref_VM
  ; dry_run: bool
  ; live: bool
  ; send_snapshots: bool
  ; check_cpu: bool
}

(* Copy VM metadata to a remote pool *)
let remote_metadata_export_import ~__context ~rpc ~session_id ~remote_address
    ~restore which =
  let subtask_of = Ref.string_of (Context.get_task_id __context) in
  let open Xmlrpc_client in
  let local_export_request =
    match which with
    | `All ->
        "all=true&include_dom0=true"
    | `Only {vm; send_snapshots; _} ->
        Printf.sprintf "export_snapshots=%b&ref=%s" send_snapshots
          (Ref.string_of vm)
  in
  let remote_import_request =
    let params =
      match which with
      | `All ->
          []
      | `Only {live; dry_run; send_snapshots; check_cpu; _} ->
          [
            Printf.sprintf "live=%b" live
          ; Printf.sprintf "dry_run=%b" dry_run
          ; Printf.sprintf "export_snapshots=%b" send_snapshots
          ; Printf.sprintf "check_cpu=%b" check_cpu
          ]
    in
    let params = Printf.sprintf "restore=%b" restore :: params in
    Printf.sprintf "%s?%s" Constants.import_metadata_uri
      (String.concat "&" params)
  in
  Helpers.call_api_functions ~__context (fun _ my_session_id ->
      let get =
        Xapi_http.http_request ~version:"1.0" ~subtask_of
          ~cookie:[("session_id", Ref.string_of my_session_id)]
          ~keep_alive:false Http.Get
          (Printf.sprintf "%s?%s" Constants.export_metadata_uri
             local_export_request
          )
      in
      let remote_task =
        Client.Task.create ~rpc ~session_id ~label:"VM metadata import"
          ~description:""
      in
      finally
        (fun () ->
          let put =
            Xapi_http.http_request ~version:"1.0" ~subtask_of
              ~cookie:
                [
                  ("session_id", Ref.string_of session_id)
                ; ("task_id", Ref.string_of remote_task)
                ]
              ~keep_alive:false Http.Put remote_import_request
          in
          debug "Piping HTTP %s to %s"
            (Http.Request.to_string get)
            (Http.Request.to_string put) ;
          ( try
              with_transport (Unix Xapi_globs.unix_domain_socket)
                (with_http get (fun (r, ifd) ->
                     debug "Content-length: %s"
                       (Option.fold ~none:"None" ~some:Int64.to_string
                          r.Http.Response.content_length
                       ) ;
                     let put =
                       {
                         put with
                         Http.Request.content_length=
                           r.Http.Response.content_length
                       }
                     in
                     debug "Connecting to %s:%d" remote_address
                       !Constants.https_port ;
                     (* Spawn a cached stunnel instance. Otherwise, once metadata tranmission completes, the connection
                        between local xapi and stunnel will be closed immediately, and the new spawned stunnel instance
                        will be revoked, this might cause the remote stunnel gets partial metadata xml file, and the
                        ripple effect is that remote xapi fails to parse metadata xml file. Using a cached stunnel can
                        not always avoid the problem since any cached stunnel entry might be evicted. However, it is
                        unlikely to happen in practice because the cache size is large enough.*)
                     with_transport
                       (SSL
                          ( SSL.make ~verify_cert:None ~use_stunnel_cache:true ()
                          , remote_address
                          , !Constants.https_port
                          )
                       )
                       (with_http put (fun (_, ofd) ->
                            let (n : int64) =
                              Xapi_stdext_unix.Unixext.copy_file
                                ?limit:r.Http.Response.content_length ifd ofd
                            in
                            debug "Written %Ld bytes" n
                        )
                       )
                 )
                )
            with Xmlrpc_client.Stunnel_connection_failed ->
              raise
                (Api_errors.Server_error
                   ( Api_errors.tls_connection_failed
                   , [remote_address; string_of_int !Constants.https_port]
                   )
                )
          ) ;
          (* Wait for remote task to succeed or fail *)
          Cli_util.wait_for_task_completion rpc session_id remote_task ;
          match Client.Task.get_status ~rpc ~session_id ~self:remote_task with
          | `cancelling | `cancelled ->
              raise
                (Api_errors.Server_error
                   (Api_errors.task_cancelled, [Ref.string_of remote_task])
                )
          | `pending ->
              failwith "wait_for_task_completion failed; task is still pending"
          | `failure -> (
              let error_info =
                Client.Task.get_error_info ~rpc ~session_id ~self:remote_task
              in
              match error_info with
              | code :: params when Hashtbl.mem Datamodel.errors code ->
                  raise (Api_errors.Server_error (code, params))
              | _ ->
                  failwith
                    (Printf.sprintf "VM metadata import failed: %s"
                       (String.concat " " error_info)
                    )
            )
          | `success -> (
              debug "Remote metadata import succeeded" ;
              let result =
                Client.Task.get_result ~rpc ~session_id ~self:remote_task
              in
              try result |> Xmlrpc.of_string |> API.ref_VM_set_of_rpc
              with parse_error ->
                raise
                  Api_errors.(
                    Server_error
                      (field_type_error, [Printexc.to_string parse_error])
                  )
            )
        )
        (fun () -> Client.Task.destroy ~rpc ~session_id ~self:remote_task)
  )

let vdi_of_req ~__context (req : Http.Request.t) =
  let all = req.Http.Request.query @ req.Http.Request.cookie in
  if List.mem_assoc "vdi" all then
    let vdi = List.assoc "vdi" all in
    if Db.is_valid_ref __context (Ref.of_string vdi) then
      Some (Ref.of_string vdi)
    else
      Some (Db.VDI.get_by_uuid ~__context ~uuid:vdi)
  else
    None

let base_vdi_of_req ~__context (req : Http.Request.t) =
  let all = req.Http.Request.query @ req.Http.Request.cookie in
  if List.mem_assoc "base" all then
    let base = List.assoc "base" all in
    Some
      ( if Db.is_valid_ref __context (Ref.of_string base) then
          Ref.of_string base
        else
          Db.VDI.get_by_uuid ~__context ~uuid:base
      )
  else
    None

let sr_of_req ~__context (req : Http.Request.t) =
  let all = Http.Request.(req.cookie @ req.query) in
  if List.mem_assoc "sr_id" all then
    Some (Ref.of_string (List.assoc "sr_id" all))
  else if List.mem_assoc "sr_uuid" all then
    Some (Db.SR.get_by_uuid ~__context ~uuid:(List.assoc "sr_uuid" all))
  else
    None

module Format = struct
  type t = Raw | Vhd | Tar | Qcow

  let to_string = function
    | Raw ->
        "raw"
    | Vhd ->
        "vhd"
    | Tar ->
        "tar"
    | Qcow ->
        "qcow2"

  let of_string x =
    match String.lowercase_ascii x with
    | "raw" ->
        Some Raw
    | "vhd" ->
        Some Vhd
    | "tar" ->
        Some Tar
    | "qcow2" ->
        Some Qcow
    | _ ->
        None

  let filename ~__context vdi format =
    Printf.sprintf "%s.%s"
      (Db.VDI.get_uuid ~__context ~self:vdi)
      (to_string format)

  let content_type = function
    | Raw ->
        "application/octet-stream"
    | Vhd ->
        "application/vhd"
    | Tar ->
        "application/x-tar"
    | Qcow ->
        "application/x-qemu-disk"

  let _key = "format"

  let of_req (req : Http.Request.t) =
    let all = req.Http.Request.query @ req.Http.Request.cookie in
    if List.mem_assoc _key all then
      let x = List.assoc _key all in
      match of_string x with Some x -> `Ok x | None -> `Unknown x
    else
      `Ok Raw

  (* default *)
end

module Devicetype = struct
  type t = VIF | VBD | VGPU | VTPM

  let all = [VIF; VBD; VGPU; VTPM]

  let to_string = function
    | VIF ->
        "vif"
    | VBD ->
        "vbd"
    | VGPU ->
        "vgpu"
    | VTPM ->
        "vtpm"

  let of_string x =
    match String.lowercase_ascii x with
    | "vif" ->
        VIF
    | "vbd" ->
        VBD
    | "vgpu" ->
        VGPU
    | "vtpm" ->
        VTPM
    | other ->
        let fail fmt = Printf.ksprintf failwith fmt in
        fail "%s: Type '%s' not one of [%s]" __FUNCTION__ other
          (String.concat "; " (List.map to_string all))
end

let return_302_redirect (req : Http.Request.t) s address =
  let url =
    Uri.(
      make ~scheme:"https" ~host:address ~path:req.Http.Request.uri
        ~query:(List.map (fun (a, b) -> (a, [b])) req.Http.Request.query)
        ()
      |> to_string
    )
  in
  let headers = Http.http_302_redirect url in
  debug "HTTP 302 redirect to: %s" url ;
  Http_svr.headers s headers
