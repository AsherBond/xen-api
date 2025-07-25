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
(** Module that defines API functions for VBD objects
 * @group XenAPI functions
*)

open Xapi_vbd_helpers
open Vbdops
module Date = Clock.Date
open D

let update_allowed_operations ~__context ~self : unit =
  update_allowed_operations ~__context ~self

let assert_attachable ~__context ~self : unit =
  assert_attachable ~__context ~self

let set_mode ~__context ~self ~value =
  let vm = Db.VBD.get_VM ~__context ~self in
  Xapi_vm_lifecycle.assert_initial_power_state_is ~__context ~self:vm
    ~expected:`Halted ;
  Db.VBD.set_mode ~__context ~self ~value

let plug ~__context ~self =
  let vm = Db.VBD.get_VM ~__context ~self in
  let domid = Int64.to_int (Db.VM.get_domid ~__context ~self:vm) in
  let force_loopback_vbd = Helpers.force_loopback_vbd ~__context in
  let hvm = Helpers.has_qemu_currently ~__context ~self:vm in
  if
    System_domains.storage_driver_domain_of_vbd ~__context ~vbd:self = vm
    && not force_loopback_vbd
  then (
    debug "VBD.plug of loopback VBD '%s'" (Ref.string_of self) ;
    Storage_access.attach_and_activate ~__context ~vbd:self ~domid
      (fun attach_info ->
        let _xendisks, blockdevs, files, nbds =
          Storage_interface.implementations_of_backend attach_info
        in
        let device_path =
          match (files, blockdevs, nbds) with
          | {path} :: _, _, _ | _, {path} :: _, _ ->
              path
          | _, _, nbd :: _ ->
              debug "Using nbd-client for VBD.plug of VBD '%s'"
                (Ref.string_of self) ;
              let unix_socket_path, export_name =
                Storage_interface.parse_nbd_uri nbd
              in
              Attach_helpers.NbdClient.start_nbd_client ~unix_socket_path
                ~export_name
          | [], [], [] ->
              raise
                (Storage_interface.Storage_error
                   (Backend_error
                      ( Api_errors.internal_error
                      , [
                          "No File, BlockDevice or Nbd implementation in \
                           Datapath.attach response: "
                          ^ (Storage_interface.(rpc_of backend) attach_info
                            |> Jsonrpc.to_string
                            )
                        ]
                      )
                   )
                )
        in
        let device_path =
          let prefix = "/dev/" in
          let prefix_len = String.length prefix in
          String.sub device_path prefix_len
            (String.length device_path - prefix_len)
        in
        debug "device path: %s" device_path ;
        Db.VBD.set_device ~__context ~self ~value:device_path ;
        Db.VBD.set_currently_attached ~__context ~self ~value:true
    )
  ) else (* CA-83260: prevent HVM guests having readonly disk VBDs *)
    let dev_type = Db.VBD.get_type ~__context ~self in
    let mode = Db.VBD.get_mode ~__context ~self in
    if hvm && dev_type <> `CD && mode = `RO then
      raise
        (Api_errors.Server_error
           (Api_errors.disk_vbd_must_be_readwrite_for_hvm, [Ref.string_of self])
        ) ;
    Xapi_xenops.vbd_plug ~__context ~self

let unplug ~__context ~self =
  let vm = Db.VBD.get_VM ~__context ~self in
  let force_loopback_vbd = Helpers.force_loopback_vbd ~__context in
  if
    System_domains.storage_driver_domain_of_vbd ~__context ~vbd:self = vm
    && not force_loopback_vbd
  then (
    debug "VBD.unplug of loopback VBD '%s'" (Ref.string_of self) ;
    let domid = Int64.to_int (Db.VM.get_domid ~__context ~self:vm) in
    let device = Db.VBD.get_device ~__context ~self in
    let nbd_device_prefix = "nbd" in
    let is_nbd = Astring.String.is_prefix ~affix:nbd_device_prefix device in
    if is_nbd then
      Attach_helpers.NbdClient.stop_nbd_client ~nbd_device:("/dev/" ^ device) ;
    Storage_access.deactivate_and_detach ~__context ~vbd:self ~domid ;
    Db.VBD.set_currently_attached ~__context ~self ~value:false
  ) else
    Xapi_xenops.vbd_unplug ~__context ~self false

let unplug_force ~__context ~self =
  let vm = Db.VBD.get_VM ~__context ~self in
  let force_loopback_vbd = Helpers.force_loopback_vbd ~__context in
  if
    System_domains.storage_driver_domain_of_vbd ~__context ~vbd:self = vm
    && not force_loopback_vbd
  then
    unplug ~__context ~self
  else
    Xapi_xenops.vbd_unplug ~__context ~self true

let unplug_force_no_safety_check = unplug_force

(** Hold this mutex while resolving the 'autodetect' device names to prevent two concurrent
    VBD.creates racing with each other and choosing the same device. For simplicity keep this
    as a global lock rather than a per-VM one. Rely on the fact that the message forwarding layer
    always runs this code on the master. *)
let autodetect_mutex = Mutex.create ()

(** VBD.create doesn't require any interaction with xen *)
let create ~__context ~vM ~vDI ~device ~userdevice ~bootable ~mode ~_type
    ~unpluggable ~empty ~other_config ~currently_attached ~qos_algorithm_type
    ~qos_algorithm_params =
  (* TODO: Raise bad power state error (once all API clients make sure to onlu call the needed params in the create method) when:
     - power_state = `Halted and (device <> "" || currently_attached)
  *)
  let power_state = Db.VM.get_power_state ~__context ~self:vM in
  let suspended = power_state = `Suspended in
  let _device = if suspended then device else "" in
  let _currently_attached = if suspended then currently_attached else false in
  ( if not empty then
      let vdi_type = Db.VDI.get_type ~__context ~self:vDI in
      if
        not
          (List.mem vdi_type
             [
               `system
             ; `user
             ; `ephemeral
             ; `suspend
             ; `crashdump
             ; `metadata
             ; `rrd
             ; `pvs_cache
             ]
          )
      then
        raise
          (Api_errors.Server_error
             ( Api_errors.vdi_incompatible_type
             , [Ref.string_of vDI; Record_util.vdi_type_to_string vdi_type]
             )
          )
  ) ;
  (* All "CD" VBDs must be readonly *)
  if _type = `CD && mode <> `RO then
    raise (Api_errors.Server_error (Api_errors.vbd_cds_must_be_readonly, [])) ;
  (* Only "CD" VBDs may be empty *)
  if _type <> `CD && empty then
    raise
      (Api_errors.Server_error
         (Api_errors.vbd_not_removable_media, ["in constructor"])
      ) ;
  (* Prevent RW VBDs being created pointing to RO VDIs *)
  if mode = `RW && Db.VDI.get_read_only ~__context ~self:vDI then
    raise
      (Api_errors.Server_error (Api_errors.vdi_readonly, [Ref.string_of vDI])) ;
  (* CA-75697: Disallow VBD.create on a VM that's in the middle of a migration *)
  debug "Checking whether there's a migrate in progress..." ;
  let vm_current_ops =
    List.sort_uniq
      (fun (_ref1, op1) (_ref2, op2) -> compare op1 op2)
      (Db.VM.get_current_operations ~__context ~self:vM)
  in

  let migrate_ops = [`migrate_send; `pool_migrate] in
  let migrate_ops_in_progress =
    List.filter (fun (_, op) -> List.mem op migrate_ops) vm_current_ops
  in
  match migrate_ops_in_progress with
  | (op_ref, op_type) :: _ ->
      raise
        (Api_errors.Server_error
           ( Api_errors.other_operation_in_progress
           , [
               "VM"
             ; Ref.string_of vM
             ; Record_util.vm_operation_to_string op_type
             ; op_ref
             ]
           )
        )
  | _ ->
      Xapi_stdext_threads.Threadext.Mutex.execute autodetect_mutex (fun () ->
          let possibilities =
            match
              Xapi_vm_helpers.allowed_VBD_devices ~__context ~vm:vM ~_type
            with
            | `Supported, xs ->
                xs
            | `FloppyPVUnsupported, _ ->
                raise
                  (Api_errors.Server_error
                     ( Api_errors.not_implemented
                     , ["VBD of type 'floppy' is not supported on PV domain"]
                     )
                  )
          in
          let raise_invalid_device () =
            raise Api_errors.(Server_error (invalid_device, [userdevice]))
          in
          if not (valid_device userdevice ~_type) then
            raise_invalid_device () ;
          (* Resolve the "autodetect" into a fixed device name now *)
          let userdevice =
            if userdevice <> "autodetect" then
              userdevice
            else
              match (_type, possibilities) with
              | _, [] ->
                  raise_invalid_device ()
              | `Floppy, dev :: _ ->
                  Device_number.to_linux_device dev
              | (`CD | `Disk), dev :: _ ->
                  string_of_int (Device_number.disk dev)
          in
          let uuid = Uuidx.make () in
          let ref = Ref.make () in
          debug "VBD.create (device = %s; uuid = %s; ref = %s)" userdevice
            (Uuidx.to_string uuid) (Ref.string_of ref) ;
          (* Check that the device is definitely unique. If the requested device is numerical
             		   (eg 1) then we 'expand' it into other possible names (eg 'hdb' 'xvdb') to detect
             		   all possible clashes. *)
          let userdevices =
            Xapi_vm_helpers.possible_VBD_devices_of_string userdevice
          in
          let existing_devices =
            Xapi_vm_helpers.all_used_VBD_devices ~__context ~self:vM
          in
          if
            Xapi_stdext_std.Listext.List.intersect userdevices existing_devices
            <> []
          then
            raise
              (Api_errors.Server_error
                 (Api_errors.device_already_exists, [userdevice])
              ) ;
          (* Make people aware that non-shared disks make VMs not agile *)
          if not empty then
            assert_doesnt_make_vm_non_agile ~__context ~vm:vM ~vdi:vDI ;
          let metrics = Ref.make ()
          and metrics_uuid = Uuidx.to_string (Uuidx.make ()) in
          Db.VBD_metrics.create ~__context ~ref:metrics ~uuid:metrics_uuid
            ~io_read_kbs:0. ~io_write_kbs:0. ~last_updated:Date.epoch
            ~other_config:[] ;
          (* Enable the SM driver to specify a VBD backend kind for the VDI *)
          let other_config =
            try
              let vdi_sc = Db.VDI.get_sm_config ~__context ~self:vDI in
              let k = Xapi_globs.vbd_backend_key in
              let v = List.assoc k vdi_sc in
              (k, v) :: other_config
            with _ -> other_config
          in
          Db.VBD.create ~__context ~ref ~uuid:(Uuidx.to_string uuid)
            ~current_operations:[] ~allowed_operations:[] ~storage_lock:false
            ~vM ~vDI ~userdevice ~device:_device ~bootable ~mode ~_type
            ~unpluggable ~empty ~reserved:false ~qos_algorithm_type
            ~qos_algorithm_params ~qos_supported_algorithms:[]
            ~currently_attached:_currently_attached ~status_code:Int64.zero
            ~status_detail:"" ~runtime_properties:[] ~other_config ~metrics ;
          update_allowed_operations ~__context ~self:ref ;
          ref
      )

let destroy ~__context ~self = destroy ~__context ~self

(** Throws VBD_NOT_REMOVABLE_ERROR if the VBD doesn't represent removable
    media. Currently this just means "CD" but might change in future? *)
let assert_removable ~__context ~vbd =
  if not (Helpers.is_removable ~__context ~vbd) then
    raise
      (Api_errors.Server_error
         (Api_errors.vbd_not_removable_media, [Ref.string_of vbd])
      )

(** Throws VBD_NOT_EMPTY if the VBD already has a VDI *)
let assert_empty ~__context ~vbd =
  if not (Db.VBD.get_empty ~__context ~self:vbd) then
    raise
      (Api_errors.Server_error (Api_errors.vbd_not_empty, [Ref.string_of vbd]))

(** Throws VBD_IS_EMPTY if the VBD has no VDI *)
let assert_not_empty ~__context ~vbd =
  if Db.VBD.get_empty ~__context ~self:vbd then
    raise
      (Api_errors.Server_error (Api_errors.vbd_is_empty, [Ref.string_of vbd]))

(** Throws BAD_POWER_STATE if the VM is suspended *)
let assert_not_suspended ~__context ~vm =
  if Db.VM.get_power_state ~__context ~self:vm = `Suspended then
    let expected =
      String.concat ", "
        (List.map Record_util.vm_power_state_to_lowercase_string
           [`Halted; `Running]
        )
    in
    let error_params =
      [
        Ref.string_of vm
      ; expected
      ; Record_util.vm_power_state_to_lowercase_string `Suspended
      ]
    in
    raise (Api_errors.Server_error (Api_errors.vm_bad_power_state, error_params))

let assert_ok_to_insert ~__context ~vbd ~vdi =
  let vm = Db.VBD.get_VM ~__context ~self:vbd in
  assert_not_suspended ~__context ~vm ;
  assert_removable ~__context ~vbd ;
  assert_empty ~__context ~vbd ;
  Xapi_vdi_helpers.assert_managed ~__context ~vdi ;
  assert_doesnt_make_vm_non_agile ~__context ~vm ~vdi

let insert ~__context ~vbd ~vdi =
  assert_ok_to_insert ~__context ~vbd ~vdi ;
  Xapi_xenops.vbd_insert ~__context ~self:vbd ~vdi

let assert_ok_to_eject ~__context ~vbd =
  let vm = Db.VBD.get_VM ~__context ~self:vbd in
  assert_removable ~__context ~vbd ;
  assert_not_empty ~__context ~vbd ;
  assert_not_suspended ~__context ~vm

let eject ~__context ~vbd =
  assert_ok_to_eject ~__context ~vbd ;
  Xapi_xenops.vbd_eject ~__context ~self:vbd

let pause ~__context ~self =
  let vdi = Db.VBD.get_VDI ~__context ~self in
  let sr = Db.VDI.get_SR ~__context ~self:vdi |> Ref.string_of in
  raise (Api_errors.Server_error (Api_errors.sr_operation_not_supported, [sr]))

let unpause = pause
