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
(** Common code between the fake and real servers for dealing with VMs.
 * @group Virtual-Machine Management
*)

open Xapi_vm_memory_constraints
open Xapi_network_attach_helpers
module Listext = Xapi_stdext_std.Listext
module Date = Clock.Date

let finally = Xapi_stdext_pervasives.Pervasiveext.finally

module XenAPI = Client.Client

module D = Debug.Make (struct let name = "xapi_vm_helpers" end)

open D
open Workload_balancing

module SRSet = Set.Make (struct
  type t = API.ref_SR

  let compare = Stdlib.compare
end)

module HostMap = Map.Make (struct
  type t = [`host] Ref.t

  let compare = Ref.compare
end)

let compute_memory_overhead ~__context ~vm =
  let vm_record = Db.VM.get_record ~__context ~self:vm in
  Memory_check.vm_compute_memory_overhead ~vm_record

let update_memory_overhead ~__context ~vm =
  Db.VM.set_memory_overhead ~__context ~self:vm
    ~value:(compute_memory_overhead ~__context ~vm)

(* To support clients that are not aware of the newer domain_type field yet and
 * have set (only) the old HVM_boot_policy field. *)
let derive_domain_type ~hVM_boot_policy =
  if hVM_boot_policy = "" then
    `pv
  else
    `hvm

(* Ensure that the domain-type is specified; upgrade from boot policy if needed *)
let ensure_domain_type_is_specified ~__context ~self =
  if Db.VM.get_domain_type ~__context ~self = `unspecified then
    Db.VM.get_HVM_boot_policy ~__context ~self |> fun hbp ->
    derive_domain_type ~hVM_boot_policy:hbp |> fun value ->
    Db.VM.set_domain_type ~__context ~self ~value

let derive_hvm_boot_policy ~domain_type =
  if domain_type = `hvm then
    Constants.hvm_default_boot_policy
  else
    ""

(* Overrides for database set functions: ************************************************)
let set_actions_after_crash ~__context ~self ~value =
  Db.VM.set_actions_after_crash ~__context ~self ~value

let set_is_a_template ~__context ~self ~value =
  (* We define a 'set_is_a_template false' as 'install time' *)
  info "VM.set_is_a_template('%b')" value ;
  let m = Db.VM.get_metrics ~__context ~self in
  ( if not value then
      try Db.VM_metrics.set_install_time ~__context ~self:m ~value:(Date.now ())
      with _ ->
        warn
          "Could not update VM install time because metrics object was missing"
    else
      (* VM must be halted, or we couldn't have got this far.
         		 * If we have a halted VM with ha_always_run = true, ha_restart_priority = "restart"
         		 * and HA is enabled on the pool, then HA is about to restart the VM and we should
         		 * block converting it into a template.
         		 *
         		 * This logic can't live in the allowed_operations code, or we'd have to update VM.allowed_operations
         		 * across the pool when enabling or disabling HA. *)
      let ha_enabled =
        Db.Pool.get_ha_enabled ~__context ~self:(Helpers.get_pool ~__context)
      in
      if ha_enabled && Helpers.is_xha_protected ~__context ~self then
        raise
          (Api_errors.Server_error
             (Api_errors.vm_is_protected, [Ref.string_of self])
          )
      (* If the VM is not protected then we can convert the VM to a template,
         		 * but we should clear the ha_always_run flag
         		 * (which will be true if the VM has ha_restart_priority = "restart" and was shut down from inside).
         		 *
         		 * We don't want templates to have this flag, or HA will try to start them. *)
      else
        Db.VM.set_ha_always_run ~__context ~self ~value:false ;
      (* Detach all VUSBs before set VM as a template *)
      let vusbs = Db.VM.get_VUSBs ~__context ~self in
      List.iter
        (fun vusb -> try Db.VUSB.destroy ~__context ~self:vusb with _ -> ())
        vusbs ;
      (* Destroy any attached pvs proxies *)
      Db.VM.get_VIFs ~__context ~self
      |> List.filter_map (fun vif ->
             Pvs_proxy_control.find_proxy_for_vif ~__context ~vif
         )
      |> List.rev
      |> List.iter (fun p -> Db.PVS_proxy.destroy ~__context ~self:p) ;
      (* Remove from any VM groups when we templatize it *)
      Db.VM.set_groups ~__context ~self ~value:[] ;
      (* Delete the vm metrics associated with the vm if it exists, when we templatize it *)
      finally
        (fun () -> Db.VM_metrics.destroy ~__context ~self:m)
        (fun () -> Db.VM.set_metrics ~__context ~self ~value:Ref.null)
  ) ;
  Db.VM.set_is_a_template ~__context ~self ~value

let set_is_default_template ~__context ~self ~value =
  info "VM.set_is_default_template('%b')" value ;
  (* A default template is a template but not viceversa *)
  if value && not (Db.VM.get_is_a_template ~__context ~self) then
    set_is_a_template ~__context ~self ~value ;
  (* update other_config flag for backward compatibility *)
  let other_config =
    Db.VM.get_other_config ~__context ~self
    |> List.remove_assoc Xapi_globs.default_template_key
    |> List.append [(Xapi_globs.default_template_key, string_of_bool value)]
  in
  Db.VM.set_other_config ~__context ~self ~value:other_config ;
  Db.VM.set_is_default_template ~__context ~self ~value

let update_vm_virtual_hardware_platform_version ~__context ~vm =
  let vm_record = Db.VM.get_record ~__context ~self:vm in
  (* Deduce what we can, but the guest VM might need a higher version. *)
  let visibly_required_version =
    if vm_record.API.vM_has_vendor_device then
      Xapi_globs.has_vendor_device
    else
      0L
  in
  let current_version = vm_record.API.vM_hardware_platform_version in
  if visibly_required_version > current_version then
    Db.VM.set_hardware_platform_version ~__context ~self:vm
      ~value:visibly_required_version

let destroy ~__context ~self =
  (* Used to be a call to hard shutdown here, but this will be redundant *)
  (* given the call to 'assert_operation_valid' *)
  debug "VM.destroy: deleting DB records" ;
  (* Should we be destroying blobs? It's possible to create a blob and then
     	   add its reference to multiple objects. Perhaps we want to just leave the
     	   blob? Or only delete it if there is no other reference to it? Is that
     	   even possible to know? *)
  let blobs = Db.VM.get_blobs ~__context ~self in
  List.iter
    (fun (_, self) -> try Xapi_blob.destroy ~__context ~self with _ -> ())
    blobs ;
  let other_config = Db.VM.get_other_config ~__context ~self in
  if
    List.mem_assoc Xapi_globs.default_template_key other_config
    && List.assoc Xapi_globs.default_template_key other_config = "true"
  then
    raise
      (Api_errors.Server_error (Api_errors.vm_cannot_delete_default_template, [])
      ) ;
  let appliance = Db.VM.get_appliance ~__context ~self in
  if Db.is_valid_ref __context appliance then (
    Db.VM.set_appliance ~__context ~self ~value:Ref.null ;
    Xapi_vm_appliance_lifecycle.update_allowed_operations ~__context
      ~self:appliance
  ) ;
  let vbds = Db.VM.get_VBDs ~__context ~self in
  List.iter
    (fun vbd ->
      ( try
          let metrics = Db.VBD.get_metrics ~__context ~self:vbd in
          Db.VBD_metrics.destroy ~__context ~self:metrics
        with _ -> ()
      ) ;
      try Db.VBD.destroy ~__context ~self:vbd with _ -> ()
    )
    vbds ;
  let vifs = Db.VM.get_VIFs ~__context ~self in
  List.iter
    (fun vif ->
      ( try
          let metrics = Db.VIF.get_metrics ~__context ~self:vif in
          Db.VIF_metrics.destroy ~__context ~self:metrics
        with _ -> ()
      ) ;
      try Db.VIF.destroy ~__context ~self:vif with _ -> ()
    )
    vifs ;
  let vgpus = Db.VM.get_VGPUs ~__context ~self in
  List.iter
    (fun vgpu -> try Db.VGPU.destroy ~__context ~self:vgpu with _ -> ())
    vgpus ;
  let pcis = Db.VM.get_attached_PCIs ~__context ~self in
  List.iter
    (fun pci ->
      try Db.PCI.remove_attached_VMs ~__context ~self:pci ~value:self
      with _ -> ()
    )
    pcis ;
  let vm_metrics = Db.VM.get_metrics ~__context ~self in
  (try Db.VM_metrics.destroy ~__context ~self:vm_metrics with _ -> ()) ;
  let vm_guest_metrics = Db.VM.get_guest_metrics ~__context ~self in
  ( try Db.VM_guest_metrics.destroy ~__context ~self:vm_guest_metrics
    with _ -> ()
  ) ;
  let vusbs = Db.VM.get_VUSBs ~__context ~self in
  List.iter
    (fun vusb -> try Db.VUSB.destroy ~__context ~self:vusb with _ -> ())
    vusbs ;
  Db.VM.destroy ~__context ~self

(* Validation and assertion functions *)

let invalid_value x y =
  raise (Api_errors.Server_error (Api_errors.invalid_value, [x; y]))

let value_not_supported fld v reason =
  raise
    (Api_errors.Server_error (Api_errors.value_not_supported, [fld; v; reason]))

let validate_vcpus ~__context ~vCPUs_max ~vCPUs_at_startup =
  if vCPUs_max < 1L then invalid_value "VCPUs_max" (Int64.to_string vCPUs_max) ;
  if vCPUs_at_startup < 1L then
    invalid_value "VCPUs-at-startup" (Int64.to_string vCPUs_at_startup) ;
  if vCPUs_at_startup > vCPUs_max then
    value_not_supported "VCPUs-at-startup"
      (Int64.to_string vCPUs_at_startup)
      "value greater than VCPUs-max"

let validate_memory ~__context ~snapshot:vm_record =
  let constraints = Vm_memory_constraints.extract ~vm_record in
  (* For now, we simply check that the given snapshot record has  *)
  (* memory constraints that can be coerced to valid constraints. *)
  (* In future, we can be more rigorous and require the snapshot  *)
  (* to have valid constraints without allowing coercion.         *)
  match Vm_memory_constraints.transform ~constraints with
  | Some _ ->
      ()
  (* Do nothing. *)
  | None ->
      (* The constraints could not be coerced. *)
      raise
        (Api_errors.Server_error (Api_errors.memory_constraint_violation, []))

let validate_shadow_multiplier ~hVM_shadow_multiplier =
  if hVM_shadow_multiplier < 1. then
    invalid_value "HVM_shadow_multiplier" (string_of_float hVM_shadow_multiplier)

let validate_actions_after_crash ~__context ~self ~value =
  let fld = "VM.actions_after_crash" in
  let hvm_cannot_coredump v =
    match Helpers.domain_type ~__context ~self with
    | `hvm | `pv_in_pvh | `pvh ->
        value_not_supported fld v
          "cannot invoke a coredump of an HVM, PVH or PV-in-PVH domain"
    | `pv ->
        ()
  in
  match value with
  | `rename_restart ->
      value_not_supported fld "rename_restart"
        "option would leak a domain; VMs and not domains are managed by this \
         API"
  | `coredump_and_destroy ->
      hvm_cannot_coredump "coredump_and_destroy"
  | `coredump_and_restart ->
      hvm_cannot_coredump "coredump_and_restart"
  | `destroy | `restart | `preserve ->
      ()

(* Used to sanity-check parameters before VM start *)
let validate_basic_parameters ~__context ~self ~snapshot:x =
  validate_vcpus ~__context ~vCPUs_max:x.API.vM_VCPUs_max
    ~vCPUs_at_startup:x.API.vM_VCPUs_at_startup ;
  validate_memory ~__context ~snapshot:x ;
  validate_shadow_multiplier
    ~hVM_shadow_multiplier:x.API.vM_HVM_shadow_multiplier ;
  validate_actions_after_crash ~__context ~self
    ~value:x.API.vM_actions_after_crash

let assert_vm_supports_quiesce_snapshot ~__context ~self =
  let vmr = Db.VM.get_record_internal ~__context ~self in
  if
    List.exists
      (fun vbd ->
        try
          let vdi = Db.VBD.get_VDI ~__context ~self:vbd in
          let sm_config = Db.VDI.get_sm_config ~__context ~self:vdi in
          List.assoc_opt "on_boot" sm_config = Some "reset"
        with _ -> false
      )
      vmr.Db_actions.vM_VBDs
  then
    raise
      (Api_errors.Server_error
         (Api_errors.vdi_on_boot_mode_incompatible_with_operation, [])
      ) ;
  let vmgmr =
    Xapi_vm_lifecycle.maybe_get_guest_metrics ~__context
      ~ref:vmr.Db_actions.vM_guest_metrics
  in
  if
    not
      (Xapi_vm_lifecycle.has_feature ~vmgmr ~feature:"feature-snapshot"
      || Xapi_vm_lifecycle.has_feature ~vmgmr ~feature:"feature-quiesce"
      )
  then
    raise
      (Api_errors.Server_error
         ( Api_errors.vm_snapshot_with_quiesce_not_supported
         , [Ref.string_of self]
         )
      )

let assert_hardware_platform_support ~__context ~vm ~host =
  let vm_hardware_platform_version =
    Db.VM.get_hardware_platform_version ~__context ~self:vm
  in
  let host_virtual_hardware_platform_versions =
    try
      match host with
      | Helpers.LocalObject host_ref ->
          Db.Host.get_virtual_hardware_platform_versions ~__context
            ~self:host_ref
      | Helpers.RemoteObject (rpc, session_id, host_ref) ->
          XenAPI.Host.get_virtual_hardware_platform_versions ~rpc ~session_id
            ~self:host_ref
    with Not_found ->
      (* An old host that does not understand the concept
         			 * has implicit support for version 0 *)
      [0L]
  in
  if
    not
      (List.mem vm_hardware_platform_version
         host_virtual_hardware_platform_versions
      )
  then
    let host_r =
      match host with
      | Helpers.LocalObject host_ref ->
          host_ref
      | Helpers.RemoteObject (_, _, host_ref) ->
          host_ref
    in
    raise
      (Api_errors.Server_error
         ( Api_errors.vm_host_incompatible_virtual_hardware_platform_version
         , [
             Ref.string_of host_r
           ; "["
             ^ String.concat "; "
                 (List.map Int64.to_string
                    host_virtual_hardware_platform_versions
                 )
             ^ "]"
           ; Ref.string_of vm
           ; Int64.to_string vm_hardware_platform_version
           ]
         )
      )

let assert_host_is_enabled ~__context ~host =
  (* Check the host is enabled first *)
  if not (Db.Host.get_enabled ~__context ~self:host) then
    raise
      (Api_errors.Server_error (Api_errors.host_disabled, [Ref.string_of host]))

let is_host_live ~__context host =
  try
    Db.Host_metrics.get_live ~__context
      ~self:(Db.Host.get_metrics ~__context ~self:host)
  with _ -> false

let assert_host_is_live ~__context ~host =
  let host_is_live = is_host_live ~__context host in
  if not host_is_live then
    raise (Api_errors.Server_error (Api_errors.host_not_live, []))

let which_specified_SRs_not_available_on_host ~__context ~reqd_srs ~host =
  let available_srs =
    Db.Host.get_PBDs ~__context ~self:host
    |> List.to_seq
    |> Seq.filter (fun self -> Db.PBD.get_currently_attached ~__context ~self)
    |> Seq.map (fun self -> Db.PBD.get_SR ~__context ~self)
    |> SRSet.of_seq
  in
  let not_available =
    List.filter (fun sr -> not @@ SRSet.mem sr available_srs) reqd_srs
  in
  List.iter
    (fun sr ->
      warn "Host %s cannot see SR %s (%s)"
        (Helpers.checknull (fun () ->
             Db.Host.get_name_label ~__context ~self:host
         )
        )
        (Helpers.checknull (fun () -> Db.SR.get_uuid ~__context ~self:sr))
        (Helpers.checknull (fun () -> Db.SR.get_name_label ~__context ~self:sr))
    )
    not_available ;
  not_available

exception Host_cannot_see_all_SRs

let assert_can_see_specified_SRs ~__context ~reqd_srs ~host =
  let not_available =
    which_specified_SRs_not_available_on_host ~__context ~reqd_srs ~host
  in
  if not_available <> [] then
    raise Host_cannot_see_all_SRs

let assert_can_see_SRs ~__context ~self ~host =
  let vbds = Db.VM.get_VBDs ~__context ~self in
  (* Skip empty VBDs *)
  let vbds =
    List.filter (fun self -> not (Db.VBD.get_empty ~__context ~self)) vbds
  in
  let vdis = List.map (fun self -> Db.VBD.get_VDI ~__context ~self) vbds in
  (* If VM is currently suspended then consider the suspend_VDI. Note both power_state and the suspend VDI
     	   are stored in R/O fields, not the last_boot_record *)
  let suspend_vdi =
    if Db.VM.get_power_state ~__context ~self = `Suspended then
      let vdi = Db.VM.get_suspend_VDI ~__context ~self in
      if vdi = Ref.null then [] else [vdi]
    else
      []
  in
  let reqd_srs =
    List.map (fun self -> Db.VDI.get_SR ~__context ~self) (vdis @ suspend_vdi)
  in
  let not_available =
    which_specified_SRs_not_available_on_host ~__context ~reqd_srs ~host
  in
  if not_available <> [] then
    raise
      (Api_errors.Server_error
         ( Api_errors.vm_requires_sr
         , [Ref.string_of self; Ref.string_of (List.hd not_available)]
         )
      )

let assert_can_see_networks ~__context ~self ~host =
  let vifs = Db.VM.get_VIFs ~__context ~self in
  let reqd_nets =
    List.map (fun self -> Db.VIF.get_network ~__context ~self) vifs
  in
  assert_can_see_named_networks ~__context ~vm:self ~host reqd_nets

(* IOMMU (VT-d) is required iff the VM has any vGPUs which require PCI
 * passthrough. *)
let vm_needs_iommu ~__context ~self =
  List.exists
    (fun vgpu -> Xapi_vgpu.requires_passthrough ~__context ~self:vgpu <> None)
    (Db.VM.get_VGPUs ~__context ~self)

let assert_host_has_iommu ~__context ~host =
  let chipset_info = Db.Host.get_chipset_info ~__context ~self:host in
  if List.assoc "iommu" chipset_info <> "true" then
    raise
      (Api_errors.Server_error
         (Api_errors.vm_requires_iommu, [Ref.string_of host])
      )

(* Check if there are vgpus not allocated, since we may check the mem/vgpu after reservation *)
let has_non_allocated_vgpus ~__context ~self =
  Db.VM.get_VGPUs ~__context ~self
  |> List.map (fun vgpu ->
         Db.VGPU.get_scheduled_to_be_resident_on ~__context ~self:vgpu
     )
  |> List.filter (fun pgpu -> not (Db.is_valid_ref __context pgpu))
  |> ( <> ) []

(* This function assert the host has enough gpu resource for the VM
 * The detailed method as follows
 * 1. Set the pre_allocate_list to []
 * 2. Dry run the allocation process for the first vgpu of the remainding vGPU list of the VM
 * 3.1 if step 2 failed, the assertion return with failure
 * 3.2 if step 2 succeed, accumulate the allocation for current vGPU in the pre_allocate_list
 * 4. Remove the list head from the remainding vGPU list of the VM
 * 5. Repeat step 2-4 until fail or the remainding list is empty
 * 6. Return success
 * *)
let assert_gpus_available ~__context ~self ~host =
  let vgpus = Db.VM.get_VGPUs ~__context ~self in
  let vGPU_structs = List.map (Vgpuops.vgpu_of_ref ~__context) vgpus in
  ignore
    (List.fold_left
       (fun pre_allocate_list vgpu ->
         Vgpuops.allocate_vgpu_to_gpu ~dry_run:true ~pre_allocate_list
           ~__context self host vgpu
       )
       [] vGPU_structs
    )

let assert_usbs_available ~__context ~self ~host =
  Db.VM.get_VUSBs ~__context ~self
  |> List.iter (fun vusb ->
         try
           let usb_group = Db.VUSB.get_USB_group ~__context ~self:vusb in
           let pusb =
             List.hd (Db.USB_group.get_PUSBs ~__context ~self:usb_group)
           in
           let usb_host = Db.PUSB.get_host ~__context ~self:pusb in
           assert (usb_host = host)
         with _ ->
           raise
             (Api_errors.Server_error
                ( Api_errors.operation_not_allowed
                , [
                    Printf.sprintf "VUSB %s is not available on Host %s"
                      (Ref.string_of vusb) (Ref.string_of host)
                  ]
                )
             )
     )

(* 1.To avoid redundant checks,for each VF if it was reserved, then it's no need to check remaining capacity again.
   2.Get SR-IOV Vifs by return a list of [(network1,(required_num1,PCI1));(network2,(required_num2,PCI2))....]
   Raise exn immediately when found Idle VF nums < required_num *)
let assert_netsriov_available ~__context ~self ~host =
  let sriov_networks =
    List.fold_left
      (fun acc vif ->
        let reserved_pci = Db.VIF.get_reserved_pci ~__context ~self:vif in
        if Db.is_valid_ref __context reserved_pci then
          acc
        else
          let network = Db.VIF.get_network ~__context ~self:vif in
          try
            let required, pif = List.assoc network acc in
            (network, (required + 1, pif)) :: List.remove_assoc network acc
          with Not_found -> (
            match
              Xapi_network_sriov_helpers.get_local_underlying_pif ~__context
                ~network ~host
            with
            | Some pif ->
                (network, (1, pif)) :: acc
            | None ->
                acc
          )
      )
      []
      (Db.VM.get_VIFs ~__context ~self)
  in
  List.iter
    (fun (network, (required, pif)) ->
      let pci = Db.PIF.get_PCI ~__context ~self:pif in
      if Xapi_pci.get_idle_vf_nums ~__context ~self:pci < Int64.of_int required
      then
        raise
          (Api_errors.Server_error
             ( Api_errors.network_sriov_insufficient_capacity
             , [Ref.string_of network]
             )
          )
    )
    sriov_networks

let assert_host_supports_hvm ~__context ~self ~host =
  if not (Helpers.host_supports_hvm ~__context host) then
    raise
      (Api_errors.Server_error (Api_errors.vm_hvm_required, [Ref.string_of self])
      )

let assert_enough_memory_available ~__context ~self ~host ~snapshot =
  let host_mem_available =
    Memory_check.host_compute_free_memory_with_maximum_compression ~__context
      ~host (Some self)
  in
  let policy =
    match Helpers.check_domain_type snapshot.API.vM_domain_type with
    | `hvm | `pv | `pvh ->
        Memory_check.Dynamic_min
    | `pv_in_pvh ->
        Memory_check.Static_max
  in
  let main, shadow =
    Memory_check.vm_compute_start_memory ~__context ~policy snapshot
  in
  let mem_reqd_for_vm = Int64.add main shadow in
  debug "host %s; available_memory = %Ld; memory_required = %Ld"
    (Db.Host.get_name_label ~self:host ~__context)
    host_mem_available mem_reqd_for_vm ;
  if host_mem_available < mem_reqd_for_vm then
    raise
      (Api_errors.Server_error
         ( Api_errors.host_not_enough_free_memory
         , [Int64.to_string mem_reqd_for_vm; Int64.to_string host_mem_available]
         )
      )

(* CA-233580: prevent starting a control domain on a host different from its affinity*)
let assert_matches_control_domain_affinity ~__context ~self ~host =
  if Db.VM.get_is_control_domain ~__context ~self then
    match Db.VM.get_affinity ~__context ~self with
    | x when x = Ref.null || x = host ->
        ()
    | _ ->
        raise
          (Api_errors.Server_error
             ( Api_errors.operation_not_allowed
             , [
                 "Cannot boot a control domain on a host different from its \
                  affinity"
               ]
             )
          )

let assert_enough_pcpus ~__context ~self ~host ?remote () =
  let vcpus = Db.VM.get_VCPUs_max ~__context ~self in
  let pcpus =
    Cpuid_helpers.get_host_cpu_info ~__context ~host ?remote ()
    |> Map_check.getf Cpuid_helpers.cpu_count
    |> Int64.of_int
  in
  if vcpus > pcpus then
    let platformdata = Db.VM.get_platform ~__context ~self in
    if Vm_platform.(is_true ~key:vcpu_unrestricted ~platformdata ~default:false)
    then
      warn
        "Allowing VM %s to run on host %s, even though #vCPUs > #pCPUs (%Ld > \
         %Ld), because platform:vcpu-unrestricted is set"
        (Ref.string_of self) (Ref.string_of host) vcpus pcpus
    else
      raise
        Api_errors.(
          Server_error
            (host_not_enough_pcpus, List.map Int64.to_string [vcpus; pcpus])
        )

let assert_no_legacy_vgpu ~__context ~vm =
  Db.VM.get_VGPUs ~__context ~self:vm
  |> List.map (fun self -> Db.VGPU.get_type ~__context ~self)
  |> List.iter (fun self -> Xapi_vgpu_type.assert_not_legacy ~__context ~self)

let assert_no_legacy_hardware ~__context ~vm =
  assert_no_legacy_vgpu ~__context ~vm

(** Checks to see if a VM can boot on a particular host, throws an error if not.
 * Criteria:
    - The host must support the VM's required Virtual Hardware Platform version.
    - The vCPU, memory, shadow multiplier, and actions-after-crash values must be valid.
    - For each VBD, corresponding VDI's SR must be attached on the target host.
    - For each VIF, either the Network has a PIF connecting to the target host,
    OR if no PIF is connected to the Network then the host must be the same one
    all running VMs with VIFs on the Network are running on.
    - If the VM need PCI passthrough, check the host supports IOMMU/VT-d.
    - For each vGPU, check whether a pGPU from the required GPU group is available.
    - If the VM would boot HVM, check the host supports it.
    - If the VM would boot PV, check the bootloader is supported.

 * I.e. we share storage but not (internal/PIF-less) networks: the first VIF on a
 * network pins it to the host the VM is running on.

 * We only check if a VM can boot here w.r.t. the configuration snapshot. If
 * the database is modified in parallel then this check will be inaccurate.
 * We must use the snapshot to boot the VM.

 * XXX: we ought to lock this otherwise we may violate our constraints under load
*)
let assert_can_boot_here ~__context ~self ~host ~snapshot ~do_cpuid_check
    ?(do_sr_check = true) ?(do_memory_check = true) () =
  debug "Checking whether VM %s can run on host %s" (Ref.string_of self)
    (Ref.string_of host) ;
  assert_no_legacy_hardware ~__context ~vm:self ;
  validate_basic_parameters ~__context ~self ~snapshot ;
  assert_host_is_live ~__context ~host ;
  assert_matches_control_domain_affinity ~__context ~self ~host ;
  let is_local_live_migration =
    Db.VM.get_power_state ~__context ~self = `Running
    && Db.VM.get_resident_on ~__context ~self = host
  in
  (* CA-233580: allow control domains to start on the host even if the latter is disabled *)
  if
    (not (Db.VM.get_is_control_domain ~__context ~self))
    && not is_local_live_migration
  then
    assert_host_is_enabled ~__context ~host ;
  (* Check the host can support the VM's required version of virtual hardware platform *)
  assert_hardware_platform_support ~__context ~vm:self
    ~host:(Helpers.LocalObject host) ;
  if do_cpuid_check then
    Cpuid_helpers.assert_vm_is_compatible ~__context ~vm:(`db self) ~host ;
  if do_sr_check then
    assert_can_see_SRs ~__context ~self ~host ;
  assert_can_see_networks ~__context ~self ~host ;
  if vm_needs_iommu ~__context ~self then
    assert_host_has_iommu ~__context ~host ;
  (* Assumption: a VM can have only one vGPU *)
  assert_no_legacy_vgpu ~__context ~vm:self ;
  if has_non_allocated_vgpus ~__context ~self then
    assert_gpus_available ~__context ~self ~host ;
  assert_usbs_available ~__context ~self ~host ;
  assert_netsriov_available ~__context ~self ~host ;
  ( match Helpers.domain_type ~__context ~self with
  | `hvm | `pv_in_pvh | `pvh ->
      assert_host_supports_hvm ~__context ~self ~host
  | `pv ->
      ()
  ) ;
  if do_memory_check then
    assert_enough_memory_available ~__context ~self ~host ~snapshot ;
  assert_enough_pcpus ~__context ~self ~host () ;
  debug "All fine, VM %s can run on host %s!" (Ref.string_of self)
    (Ref.string_of host)

let retrieve_wlb_recommendations ~__context ~vm ~snapshot =
  let module HostMap = Map.Make (struct
    type t = API.ref_host

    let compare = Stdlib.compare
  end) in
  let compatible_vm_or_impossible (host, recommendation) =
    let recommendation =
      match recommendation with
      | Recommendation {source; id; _} -> (
        try
          assert_can_boot_here ~__context ~self:vm ~host ~snapshot
            ~do_cpuid_check:true () ;
          recommendation
        with
        (* CPUID checks are being removed from WLB, this will become the responsibility of XAPI
         * (and ultimately Xen/libxc). Previously WLB would've assigned a score of 0.0 and a reason
         * of "HostCPUFeaturesIncompatible" to hosts that can't boot a VM due to CPU features missing.
         * WLB could call assert_can_boot_here instead of doing its own CPUID checks, however that
         * would add a lot of extra API calls (at least Number_of_hosts * Number_of_VMs).
         * Instead do this check in XAPI itself, and override WLB's response for backwards compatibility
         * with 0.0, and the same reason code that WLB would've used. This should keep observable behaviour
         * identical and work both with old and new WLBs.
         *)
        | Api_errors.Server_error (x, _)
          when x = Api_errors.vm_incompatible_with_this_host ->
            Impossible {source; id; reason= "HostCPUFeaturesIncompatible"}
        | Api_errors.Server_error (x, y) ->
            let reason = String.concat ";" (x :: y) in
            Impossible {source; id; reason}
      )
      | impossible_load ->
          impossible_load
    in
    (host, recommendation)
  in
  let only_for_all_live_hosts_or_raise recs =
    (* Recommendations cannot have hosts that are not active and there must
       at least one per active host *)
    let live_hosts = Helpers.get_live_hosts ~__context in
    if HostMap.cardinal recs <> List.length live_hosts then
      raise_malformed_response' "VMGetRecommendations"
        "VM recommendations must only target live hosts and target all of them"
        "Unknown"
    else
      () ;
    recs
  in
  (* Make sure a single recommendation is present per host. *)
  retrieve_vm_recommendations ~__context ~vm
  |> List.to_seq
  |> HostMap.of_seq
  |> only_for_all_live_hosts_or_raise
  |> HostMap.to_seq
  |> Seq.map compatible_vm_or_impossible
  |> List.of_seq

(** Returns the subset of all hosts to which the given function [choose_fn]
    can be applied without raising an exception. If the optional [vm] argument is
    present, this function additionally prints a debug message that includes the
    names of the given VM and each of the possible hosts. *)
let possible_hosts ~__context ?vm ~choose_fn () =
  (* XXXX: This function uses exceptions to control the flow of execution.  *)
  (* XXXX: This function mixes business logic with debugging functionality. *)
  let all_hosts = Db.Host.get_all ~__context in
  let choices =
    List.filter
      (fun host ->
        try
          (choose_fn ~host : unit) ;
          assert_host_is_live ~__context ~host ;
          true
        with _ -> false
      )
      all_hosts
  in
  ( match vm with
  | Some vm ->
      warn "VM %s could run on any of these hosts: [ %s ]"
        (Helpers.checknull (fun () -> Db.VM.get_name_label ~__context ~self:vm))
        (String.concat "; "
           (List.map
              (fun self ->
                Helpers.checknull (fun () ->
                    Db.Host.get_name_label ~__context ~self
                )
              )
              choices
           )
        )
  | None ->
      ()
  ) ;
  choices

(** Returns a single host (from the set of all hosts) to which the given
    function [choose_fn] can be applied without raising an exception. Raises
    [Api_errors.no_hosts_available] if no such host exists. If the optional [vm]
    argument is present, then this function additionally prints a debug message
    that includes the names of the given VM and the subset of all hosts that
    satisfy the given function [choose_fn]. *)
let choose_host ~__context ?vm ~choose_fn ?(prefer_slaves = false) () =
  let choices = possible_hosts ~__context ?vm ~choose_fn () in
  match choices with
  | [] ->
      raise (Api_errors.Server_error (Api_errors.no_hosts_available, []))
  | [h] ->
      h
  | _ ->
      let choices =
        if prefer_slaves then
          let master = Helpers.get_master ~__context in
          List.filter (( <> ) master) choices
        else
          choices
      in
      List.nth choices (Random.int (List.length choices))

(* Compute all SRs required for shutting down suspended domains *)
let compute_required_SRs_for_shutting_down_suspended_domains ~__context ~vm =
  let all_vm_vdis =
    List.filter_map
      (fun vbd ->
        if Db.VBD.get_empty ~__context ~self:vbd then
          None
        else
          Some (Db.VBD.get_VDI ~__context ~self:vbd)
      )
      (Db.VM.get_VBDs ~__context ~self:vm)
  in
  List.map (fun vdi -> Db.VDI.get_SR ~self:vdi ~__context) all_vm_vdis

(** Returns the subset of all hosts on which the given [vm] can boot. This
    function also prints a debug message identifying the given [vm] and hosts. *)
let get_possible_hosts_for_vm ~__context ~vm ~snapshot =
  let host = Db.VM.get_scheduled_to_be_resident_on ~__context ~self:vm in
  if host <> Ref.null then
    [host]
  else
    possible_hosts ~__context ~vm
      ~choose_fn:
        (assert_can_boot_here ~__context ~self:vm ~snapshot
           ~do_cpuid_check:false ()
        )
      ()

(** Performs an expensive and comprehensive check to determine whether the
    given [guest] can run on the given [host]. Returns true if and only if the
    guest can run on the host. *)
let vm_can_run_on_host ~__context ~vm ~snapshot ~do_memory_check host =
  let is_control_domain = Db.VM.get_is_control_domain ~__context ~self:vm in
  let host_has_proper_version () =
    if Helpers.rolling_upgrade_in_progress ~__context then
      Helpers.host_has_highest_version_in_pool ~__context
        ~host:(Helpers.LocalObject host)
    else
      true
  in
  let host_enabled () = Db.Host.get_enabled ~__context ~self:host in
  let host_live () =
    let host_metrics = Db.Host.get_metrics ~__context ~self:host in
    Db.Host_metrics.get_live ~__context ~self:host_metrics
  in
  let host_can_run_vm () =
    assert_can_boot_here ~__context ~self:vm ~host ~snapshot ~do_memory_check
      ~do_cpuid_check:true () ;
    true
  in
  let host_evacuate_in_progress =
    try
      let _ =
        List.find
          (fun s -> snd s = `evacuate)
          (Db.Host.get_current_operations ~__context ~self:host)
      in
      false
    with _ -> true
  in
  try
    host_has_proper_version ()
    && (is_control_domain || host_enabled ())
    (*CA-233580: allow control domains to start on a disabled host*)
    && host_live ()
    && host_can_run_vm ()
    && host_evacuate_in_progress
  with _ -> false

let vm_has_anti_affinity ~__context ~vm =
  if Pool_features.is_enabled ~__context Features.VM_groups then
    List.find_opt
      (fun g -> Db.VM_group.get_placement ~__context ~self:g = `anti_affinity)
      (Db.VM.get_groups ~__context ~self:vm)
    |> Option.map (fun group ->
           debug
             "The VM (uuid %s) is associated with an anti-affinity group \
              (uuid: %s, name: %s)"
             (Db.VM.get_uuid ~__context ~self:vm)
             (Db.VM_group.get_uuid ~__context ~self:group)
             (Db.VM_group.get_name_label ~__context ~self:group) ;
           `AntiAffinity group
       )
  else (
    debug
      "VM group feature is disabled, ignore VM anti-affinity during VM start" ;
    None
  )

let vm_has_vgpu ~__context ~vm =
  match Db.VM.get_VGPUs ~__context ~self:vm with
  | [] ->
      None
  | vgpu :: _ ->
      Some (`VGPU vgpu)

let vm_has_sriov ~__context ~vm =
  match
    Xapi_network_sriov_helpers.get_sriov_networks_from_vm ~__context ~vm
  with
  | [] ->
      None
  | network :: _ ->
      Some (`Netsriov network)

let ( >>= ) opt f = match opt with Some _ as v -> v | None -> f

let get_group_key ~__context ~vm =
  match
    vm_has_anti_affinity ~__context ~vm
    >>= vm_has_vgpu ~__context ~vm
    >>= vm_has_sriov ~__context ~vm
  with
  | Some x ->
      x
  | None ->
      `Other

(* Rank the provided hosts (visible_hosts) by the remainding capacity for the
 * give vGPU. The vGPU has an associated vGPU group
 * We get the rank preference from the vGPU grouop
 * vgpu: the vGPU used to rank the provided hosts
 * visible_hosts: the hosts will be ranked*)
let rank_hosts_by_best_vgpu ~__context vgpu visible_hosts =
  match visible_hosts with
  | [] ->
      raise (Api_errors.Server_error (Api_errors.no_hosts_available, []))
  | hosts ->
      let vgpu_type = Db.VGPU.get_type ~__context ~self:vgpu in
      let gpu_group = Db.VGPU.get_GPU_group ~__context ~self:vgpu in
      let pgpus_in_group = Db.GPU_group.get_PGPUs ~__context ~self:gpu_group in
      let ordering =
        match
          Db.GPU_group.get_allocation_algorithm ~__context ~self:gpu_group
        with
        | `depth_first ->
            `ascending
        | `breadth_first ->
            `descending
      in
      Helpers.group_by ~ordering
        (fun host ->
          (* For every host
           * 1. get all the pGPUs in the associated gpu_group
           * 2. accumulate all the remaining capapcity for the vGPU
           * 3. use the accumulated capacity as the ranking metrics*)
          Db.Host.get_PGPUs ~__context ~self:host
          |> Listext.List.intersect pgpus_in_group
          |> List.fold_left
               (fun count self ->
                 Int64.add count
                   (Xapi_pgpu_helpers.get_remaining_capacity ~__context ~self
                      ~vgpu_type ~pre_allocate_list:[]
                   )
               )
               0L
        )
        hosts
      |> List.map (fun g -> List.map fst g)

let host_to_vm_count_map ~__context group =
  let host_of_vm vm =
    let vm_rec = Db.VM.get_record ~__context ~self:vm in
    (* 1. When a VM starts migrating, it's 'scheduled_to_be_resident_on' will be set,
          while its 'resident_on' is not cleared. In this case,
          'scheduled_to_be_resident_on' should be treated as its running host.
       2. For paused VM, its 'resident_on' has value, but it will not be considered
          while computing the amount of VMs. *)
    match
      ( vm_rec.API.vM_scheduled_to_be_resident_on
      , vm_rec.API.vM_resident_on
      , vm_rec.API.vM_power_state
      )
    with
    | sh, _, _ when sh <> Ref.null ->
        Some sh
    | _, h, `Running when h <> Ref.null ->
        Some h
    | _ ->
        None
  in
  Db.VM_group.get_VMs ~__context ~self:group
  |> List.fold_left
       (fun m vm ->
         match host_of_vm vm with
         | Some h ->
             HostMap.update h
               (fun c -> Option.(value ~default:0 c |> succ |> some))
               m
         | None ->
             m
       )
       HostMap.empty

let rank_hosts_by_vm_cnt_in_group ~__context group hosts =
  let host_map = host_to_vm_count_map ~__context group in
  Helpers.group_by ~ordering:`ascending
    (fun h -> HostMap.find_opt h host_map |> Option.value ~default:0)
    hosts

let get_affinity_host ~__context ~vm =
  match Db.VM.get_affinity ~__context ~self:vm with
  | ref when Db.is_valid_ref __context ref ->
      Some ref
  | _ ->
      None

(* Group all hosts to 2 parts:
   1. A list of affinity host (only one host).
   2. A list of lists, each list contains hosts with the same number of
      running VM in that anti-affinity group.
      These lists are sorted by VM's count.
   Combine these lists into one list. The list is like below:
   [ [host1] (affinity host)
   , [host2, host3] (no VM running)
   , [host4, host5] (one VM running)
   , [host6, host7] (more VMs running)
   , ...
   ]
*)
let rank_hosts_by_placement ~__context ~vm ~group =
  let hosts = Db.Host.get_all ~__context in
  let affinity_host = get_affinity_host ~__context ~vm in
  let hosts_without_affinity =
    Option.fold ~none:hosts
      ~some:(fun host -> List.filter (( <> ) host) hosts)
      affinity_host
  in
  let sorted_hosts =
    hosts_without_affinity
    |> rank_hosts_by_vm_cnt_in_group ~__context group
    |> List.(map (map fst))
  in
  match affinity_host with
  | Some host ->
      [host] :: sorted_hosts
  | None ->
      sorted_hosts

let rec select_host_from_ranked_lists ~vm ~host_selector ~ranked_host_lists =
  match ranked_host_lists with
  | [] ->
      raise (Api_errors.Server_error (Api_errors.no_hosts_available, []))
  | hosts :: less_optimal_groups_of_hosts -> (
      let hosts_str = String.concat ";" (List.map Ref.string_of hosts) in
      debug
        "Attempting to select host for VM (%s) in a group of equally optimal \
         hosts [ %s ]"
        (Ref.string_of vm) hosts_str ;
      try host_selector hosts
      with _ ->
        info
          "Failed to select host for VM (%s) in any of [ %s ], continue to \
           select from less optimal hosts"
          (Ref.string_of vm) hosts_str ;
        select_host_from_ranked_lists ~vm ~host_selector
          ~ranked_host_lists:less_optimal_groups_of_hosts
    )

(* Selects a single host from the set of all hosts on which the given [vm] can boot.
   Raises [Api_errors.no_hosts_available] if no such host exists.
   1.Take anti-affinity, or VGPU, or Network SR-IOV as a group_key for group all hosts into host list list
   2.helper function's order determine the priority of resources,now anti-affinity has the highest priority,
     VGPU is the second, Network SR-IOV is the lowest
   3.If no key found in VM,then host_lists will be [all_hosts] *)
let choose_host_for_vm_no_wlb ~__context ~vm ~snapshot =
  let validate_host =
    vm_can_run_on_host ~__context ~vm ~snapshot ~do_memory_check:true
  in
  let all_hosts = Db.Host.get_all ~__context in
  let group_key = get_group_key ~__context ~vm in
  let host_lists =
    match group_key with
    | `Other ->
        [all_hosts]
    | `AntiAffinity group ->
        rank_hosts_by_placement ~__context ~vm ~group
    | `VGPU vgpu ->
        let can_host_vm ~__context host vm =
          try
            assert_gpus_available ~__context ~self:vm ~host ;
            true
          with _ -> false
        in
        all_hosts
        |> List.filter (fun self -> can_host_vm ~__context self vm)
        |> rank_hosts_by_best_vgpu ~__context vgpu
    | `Netsriov network ->
        let host_group =
          Xapi_network_sriov_helpers.group_hosts_by_best_sriov ~__context
            ~network
          |> List.map (fun g -> List.map fst g)
        in
        if host_group <> [] then
          host_group
        else
          raise
            (Api_errors.Server_error
               ( Api_errors.network_sriov_insufficient_capacity
               , [Ref.string_of network]
               )
            )
  in
  let host_selector =
    Xapi_vm_placement.select_host __context vm validate_host
  in
  try
    select_host_from_ranked_lists ~vm ~host_selector
      ~ranked_host_lists:host_lists
  with
  | Api_errors.Server_error (x, []) when x = Api_errors.no_hosts_available ->
    debug
      "No hosts guaranteed to satisfy VM constraints. Trying again ignoring \
       memory checks" ;
    let validate_host =
      vm_can_run_on_host ~__context ~vm ~snapshot ~do_memory_check:false
    in
    List.concat host_lists
    |> Xapi_vm_placement.select_host __context vm validate_host

(** choose_host_for_vm will use WLB as long as it is enabled and there
    is no pool.other_config["wlb_choose_host_disable"] = "true". *)
let choose_host_uses_wlb ~__context =
  Workload_balancing.check_wlb_enabled ~__context
  && not
       (List.exists
          (fun (k, v) ->
            k = "wlb_choose_host_disable" && String.lowercase_ascii v = "true"
          )
          (Db.Pool.get_other_config ~__context
             ~self:(Helpers.get_pool ~__context)
          )
       )

(** Given a virtual machine, returns a host it can boot on, giving
    priority to an affinity host if one is present. WARNING: called
    while holding the global lock from the message forwarding layer. *)
let choose_host_for_vm ~__context ~vm ~snapshot =
  if choose_host_uses_wlb ~__context then (
    try
      let possible_rec (host, recommendation) =
        match recommendation with
        | Recommendation {id; score; _} ->
            Some (host, score, id)
        | _ ->
            None
      in
      let cmp_descending (_, s, _) (_, s', _) = Float.compare s' s in
      let all_hosts =
        retrieve_wlb_recommendations ~__context ~vm ~snapshot
        |> List.filter_map possible_rec
        |> List.sort cmp_descending
      in
      let pp_host (host, score, _) =
        let hostname = Db.Host.get_name_label ~__context ~self:host in
        Printf.sprintf "%s %f" hostname score
      in
      debug "Hosts sorted by priority: %s"
        (all_hosts |> List.map pp_host |> String.concat "; ") ;
      match all_hosts with
      | (h, _, r) :: _ ->
          debug "Wlb has recommended host %s"
            (Db.Host.get_name_label ~__context ~self:h) ;
          let action =
            Db.Task.get_name_label ~__context
              ~self:(Context.get_task_id __context)
          in
          let oc =
            Db.Pool.get_other_config ~__context
              ~self:(Helpers.get_pool ~__context)
          in
          Db.Task.set_other_config ~__context
            ~self:(Context.get_task_id __context)
            ~value:
              ([
                 ("wlb_advised", r)
               ; ("wlb_action", action)
               ; ("wlb_action_obj_type", "VM")
               ; ("wlb_action_obj_ref", Ref.string_of vm)
               ]
              @ oc
              ) ;
          h
      | _ ->
          debug "Wlb has no recommendations. Using original algorithm" ;
          choose_host_for_vm_no_wlb ~__context ~vm ~snapshot
    with
    | Api_errors.Server_error (error_type, error_detail) ->
        debug
          "Encountered error when using wlb for choosing host \"%s: %s\". \
           Using original algorithm"
          error_type
          (String.concat "" error_detail) ;
        ( try
            let uuid = Db.VM.get_uuid ~__context ~self:vm in
            let message_body =
              Printf.sprintf
                "Wlb consultation for VM '%s' failed (pool uuid: %s)"
                (Db.VM.get_name_label ~__context ~self:vm)
                (Db.Pool.get_uuid ~__context ~self:(Helpers.get_pool ~__context))
            in
            let name, priority = Api_messages.wlb_failed in
            ignore
              (Xapi_message.create ~__context ~name ~priority ~cls:`VM
                 ~obj_uuid:uuid ~body:message_body
              )
          with _ -> ()
        ) ;
        choose_host_for_vm_no_wlb ~__context ~vm ~snapshot
    | _ ->
        debug
          "Encountered an unknown error when using wlb for choosing host. \
           Using original algorithm" ;
        choose_host_for_vm_no_wlb ~__context ~vm ~snapshot
  ) else (
    debug
      "Using wlb recommendations for choosing a host has been disabled or wlb \
       is not available. Using original algorithm" ;
    choose_host_for_vm_no_wlb ~__context ~vm ~snapshot
  )

type set_cpus_number_fn =
  __context:Context.t -> self:API.ref_VM -> int -> API.vM_t -> int64 -> unit

let validate_HVM_shadow_multiplier multiplier =
  if multiplier < 1. then
    invalid_value "multiplier" (string_of_float multiplier)

(** Sets the HVM shadow multiplier for a {b Halted} VM. Runs on the master. *)
let set_HVM_shadow_multiplier ~__context ~self ~value =
  if Db.VM.get_power_state ~__context ~self <> `Halted then
    failwith
      "assertion_failed: set_HVM_shadow_multiplier should only be called when \
       the VM is Halted" ;
  validate_HVM_shadow_multiplier value ;
  Db.VM.set_HVM_shadow_multiplier ~__context ~self ~value ;
  update_memory_overhead ~__context ~vm:self

let inclusive_range a b = List.init (b - a + 1) (fun k -> a + k)

let vbd_inclusive_range hvm a b =
  List.filter_map (Device_number.of_disk_number hvm) (inclusive_range a b)

let vif_inclusive_range a b = List.map string_of_int (inclusive_range a b)

(* These are high-watermark limits as documented in CA-6525. Individual guest types
   may be further restricted. *)

(* HVM guests without PV drivers only support 4 VBD or VIF devices, where VMs with drivers follow
 * the wider limits below. We used to make this distinction here when setting allowed_{VBD,VIF}_devices.
 * However, detecting PV drivers at the right time is tricky, so we have simplified this to always
 * allow the PV range. *)
let allowed_VBD_devices_HVM = vbd_inclusive_range true 0 254

let allowed_VBD_devices_PV = vbd_inclusive_range false 0 254

let allowed_VBD_devices_control_domain = vbd_inclusive_range false 0 255

let allowed_VBD_devices_HVM_floppy =
  List.filter_map
    (fun x -> Device_number.(make Floppy ~disk:x ~partition:0))
    (inclusive_range 0 1)

let allowed_VIF_devices_HVM = vif_inclusive_range 0 6

let allowed_VIF_devices_PV = vif_inclusive_range 0 6

(** [possible_VBD_devices_of_string s] returns a list of Device_number.t which
    	represent possible interpretations of [s]. *)
let possible_VBD_devices_of_string s =
  (* NB userdevice fields are arbitrary strings and device fields may be "" *)
  let parse hvm x = Device_number.of_string ~hvm x in
  List.filter_map Fun.id [parse true s; parse false s]

(** [all_used_VBD_devices __context self] returns a list of Device_number.t
    	which are considered to be already in-use in the VM *)
let all_used_VBD_devices ~__context ~self =
  let all = Db.VM.get_VBDs ~__context ~self in
  let existing_devices =
    let all_devices =
      List.map (fun self -> Db.VBD.get_device ~__context ~self) all
    in
    let all_devices2 =
      List.map (fun self -> Db.VBD.get_userdevice ~__context ~self) all
    in
    all_devices @ all_devices2
  in
  List.concat_map possible_VBD_devices_of_string existing_devices

let allowed_VBD_devices ~__context ~vm ~_type =
  let will_have_qemu = Helpers.will_have_qemu ~__context ~self:vm in
  let is_control_domain = Db.VM.get_is_control_domain ~__context ~self:vm in
  let supported, all_devices =
    match (will_have_qemu, is_control_domain, _type) with
    | true, _, `Floppy ->
        (`Supported, allowed_VBD_devices_HVM_floppy)
    | false, _, `Floppy ->
        (`FloppyPVUnsupported, [])
    | false, true, _ ->
        (`Supported, allowed_VBD_devices_control_domain)
    | false, false, _ ->
        (`Supported, allowed_VBD_devices_PV)
    | true, _, _ ->
        (`Supported, allowed_VBD_devices_HVM)
  in
  (* Filter out those we've already got VBDs for *)
  let used_devices = all_used_VBD_devices ~__context ~self:vm in
  ( supported
  , List.filter (fun dev -> not (List.mem dev used_devices)) all_devices
  )

let allowed_VIF_devices ~__context ~vm =
  let will_have_qemu = Helpers.will_have_qemu ~__context ~self:vm in
  let all_devices =
    if will_have_qemu then allowed_VIF_devices_HVM else allowed_VIF_devices_PV
  in
  (* Filter out those we've already got VIFs for *)
  let all_vifs = Db.VM.get_VIFs ~__context ~self:vm in
  let used_devices =
    List.map (fun vif -> Db.VIF.get_device ~__context ~self:vif) all_vifs
  in
  List.filter (fun dev -> not (List.mem dev used_devices)) all_devices

let delete_guest_metrics ~__context ~self:vm =
  (* Delete potentially stale guest metrics object *)
  let guest_metrics = Db.VM.get_guest_metrics ~__context ~self:vm in
  Db.VM.set_guest_metrics ~__context ~self:vm ~value:Ref.null ;
  try Db.VM_guest_metrics.destroy ~__context ~self:guest_metrics with _ -> ()

let copy_metrics ~__context ~vm =
  (* Copy the old metrics if available, otherwise generate a fresh one *)
  let m =
    let mref = Db.VM.get_metrics ~__context ~self:vm in
    if Db.is_valid_ref __context mref then
      Some (Db.VM_metrics.get_record_internal ~__context ~self:mref)
    else
      None
  in
  let metrics = Ref.make ()
  and metrics_uuid = Uuidx.to_string (Uuidx.make ()) in
  Db.VM_metrics.create ~__context ~ref:metrics ~uuid:metrics_uuid
    ~memory_actual:
      (Option.fold ~none:0L
         ~some:(fun x -> x.Db_actions.vM_metrics_memory_actual)
         m
      )
    ~vCPUs_number:
      (Option.fold ~none:0L
         ~some:(fun x -> x.Db_actions.vM_metrics_VCPUs_number)
         m
      )
    ~vCPUs_utilisation:
      (Option.fold
         ~none:[(0L, 0.)]
         ~some:(fun x -> x.Db_actions.vM_metrics_VCPUs_utilisation)
         m
      )
    ~vCPUs_CPU:
      (Option.fold ~none:[] ~some:(fun x -> x.Db_actions.vM_metrics_VCPUs_CPU) m)
    ~vCPUs_params:
      (Option.fold ~none:[]
         ~some:(fun x -> x.Db_actions.vM_metrics_VCPUs_params)
         m
      )
    ~vCPUs_flags:
      (Option.fold ~none:[]
         ~some:(fun x -> x.Db_actions.vM_metrics_VCPUs_flags)
         m
      )
    ~start_time:
      (Option.fold ~none:Date.epoch
         ~some:(fun x -> x.Db_actions.vM_metrics_start_time)
         m
      )
    ~install_time:
      (Option.fold ~none:Date.epoch
         ~some:(fun x -> x.Db_actions.vM_metrics_install_time)
         m
      )
    ~state:
      (Option.fold ~none:[] ~some:(fun x -> x.Db_actions.vM_metrics_state) m)
    ~last_updated:
      (Option.fold ~none:Date.epoch
         ~some:(fun x -> x.Db_actions.vM_metrics_last_updated)
         m
      )
    ~other_config:
      (Option.fold ~none:[]
         ~some:(fun x -> x.Db_actions.vM_metrics_other_config)
         m
      )
    ~nomigrate:
      (Option.fold ~none:false
         ~some:(fun x -> x.Db_actions.vM_metrics_nomigrate)
         m
      )
    ~hvm:(Option.fold ~none:false ~some:(fun x -> x.Db_actions.vM_metrics_hvm) m)
    ~nested_virt:
      (Option.fold ~none:false
         ~some:(fun x -> x.Db_actions.vM_metrics_nested_virt)
         m
      )
    ~current_domain_type:
      (Option.fold ~none:`unspecified
         ~some:(fun x -> x.Db_actions.vM_metrics_current_domain_type)
         m
      ) ;
  metrics

let copy_guest_metrics ~__context ~vm =
  (* Copy the old metrics if available, otherwise return Ref.null *)
  try
    let gm = Db.VM.get_guest_metrics ~__context ~self:vm in
    let all = Db.VM_guest_metrics.get_record ~__context ~self:gm in
    let ref = Ref.make () in
    Db.VM_guest_metrics.create ~__context ~ref
      ~uuid:(Uuidx.to_string (Uuidx.make ()))
      ~os_version:all.API.vM_guest_metrics_os_version
      ~netbios_name:all.API.vM_guest_metrics_netbios_name
      ~pV_drivers_version:all.API.vM_guest_metrics_PV_drivers_version
      ~pV_drivers_up_to_date:all.API.vM_guest_metrics_PV_drivers_up_to_date
      ~memory:all.API.vM_guest_metrics_memory
      ~disks:all.API.vM_guest_metrics_disks
      ~networks:all.API.vM_guest_metrics_networks
      ~services:all.API.vM_guest_metrics_services
      ~pV_drivers_detected:all.API.vM_guest_metrics_PV_drivers_detected
      ~other:all.API.vM_guest_metrics_other
      ~last_updated:all.API.vM_guest_metrics_last_updated
      ~other_config:all.API.vM_guest_metrics_other_config
      ~live:all.API.vM_guest_metrics_live
      ~can_use_hotplug_vbd:all.API.vM_guest_metrics_can_use_hotplug_vbd
      ~can_use_hotplug_vif:all.API.vM_guest_metrics_can_use_hotplug_vif ;
    ref
  with _ -> Ref.null

let start_delay ~__context ~vm =
  let start_delay = Db.VM.get_start_delay ~__context ~self:vm in
  Thread.delay (Int64.to_float start_delay)

let shutdown_delay ~__context ~vm =
  let shutdown_delay = Db.VM.get_shutdown_delay ~__context ~self:vm in
  Thread.delay (Int64.to_float shutdown_delay)

let list_required_vdis ~__context ~self =
  let vbds = Db.VM.get_VBDs ~__context ~self in
  let vbds_excluding_cd =
    List.filter (fun vbd -> Db.VBD.get_type ~__context ~self:vbd <> `CD) vbds
  in
  List.map (fun vbd -> Db.VBD.get_VDI ~__context ~self:vbd) vbds_excluding_cd

(* Find the SRs of all VDIs which have VBDs attached to the VM. *)
let list_required_SRs ~__context ~self =
  list_required_vdis ~__context ~self
  |> List.to_seq
  |> Seq.map (fun self -> Db.VDI.get_SR ~__context ~self)
  |> Seq.filter (fun self -> Db.SR.get_content_type ~__context ~self <> "iso")
  |> SRSet.of_seq
  |> SRSet.elements

(* Check if the database referenced by session_to *)
(* contains the SRs required to recover the VM. *)
let assert_can_be_recovered ~__context ~self ~session_to =
  (* Get the required SR uuids from the foreign database. *)
  let required_SRs = list_required_SRs ~__context ~self in
  let required_SR_uuids =
    List.map (fun sr -> Db.SR.get_uuid ~__context ~self:sr) required_SRs
  in
  (* Try to look up the SRs by uuid in the local database. *)
  try
    Server_helpers.exec_with_new_task ~session_id:session_to
      "Looking for required SRs" (fun __context_to ->
        List.iter
          (fun sr_uuid ->
            let sr = Db.SR.get_by_uuid ~__context:__context_to ~uuid:sr_uuid in
            (* Check if SR has any attached PBDs. *)
            let pbds = Db.SR.get_PBDs ~__context:__context_to ~self:sr in
            let attached_pbds =
              List.filter
                (fun pbd ->
                  Db.PBD.get_currently_attached ~__context:__context_to
                    ~self:pbd
                )
                pbds
            in
            if attached_pbds = [] then
              raise
                (Api_errors.Server_error
                   ( Api_errors.vm_requires_sr
                   , [Ref.string_of self; Ref.string_of sr]
                   )
                )
          )
          required_SR_uuids
    )
  with Db_exn.Read_missing_uuid (_, _, sr_uuid) ->
    (* Throw exception containing the ref of the first SR which wasn't found. *)
    let sr = Db.SR.get_by_uuid ~__context ~uuid:sr_uuid in
    raise
      (Api_errors.Server_error
         (Api_errors.vm_requires_sr, [Ref.string_of self; Ref.string_of sr])
      )

let get_SRs_required_for_recovery ~__context ~self ~session_to =
  let required_SR_list = list_required_SRs ~__context ~self in
  Server_helpers.exec_with_new_task ~session_id:session_to
    "Looking for the required SRs" (fun __context_to ->
      List.filter
        (fun sr_ref ->
          let sr_uuid = Db.SR.get_uuid ~__context ~self:sr_ref in
          try
            let sr = Db.SR.get_by_uuid ~__context:__context_to ~uuid:sr_uuid in
            let pbds = Db.SR.get_PBDs ~__context:__context_to ~self:sr in
            let attached_pbds =
              List.filter
                (fun pbd ->
                  Db.PBD.get_currently_attached ~__context:__context_to
                    ~self:pbd
                )
                pbds
            in
            if attached_pbds = [] then true else false
          with Db_exn.Read_missing_uuid _ -> true
        )
        required_SR_list
  )

(* BIOS strings *)
let assert_valid_bios_strings ~__context ~value =
  (* Validate BIOS string keys *)
  (* Validate size of value provided is within bios_string_limit_size and not empty *)
  (* Validate value chars are printable ASCII characters *)
  value
  |> List.iter (fun (k, v) ->
         if not (List.mem k Constants.settable_vm_bios_string_keys) then
           raise
             (Api_errors.Server_error
                (Api_errors.invalid_value, [k; "Unknown key"])
             ) ;
         match String.length v with
         | 0 ->
             raise
               (Api_errors.Server_error
                  (Api_errors.invalid_value, [k; "Value provided is empty"])
               )
         | len when len > Constants.bios_string_limit_size ->
             let err =
               Printf.sprintf "%s has length more than %d characters" v
                 Constants.bios_string_limit_size
             in
             raise (Api_errors.Server_error (Api_errors.invalid_value, [k; err]))
         | _ ->
             String.iter
               (fun c ->
                 if c < Char.chr 32 || c >= Char.chr 127 then
                   raise
                     (Api_errors.Server_error
                        ( Api_errors.invalid_value
                        , [k; v ^ " has non-printable ASCII characters"]
                        )
                     )
               )
               v
     )

let copy_bios_strings ~__context ~vm ~host =
  (* only allow to fill in BIOS strings if they are not yet set *)
  let current_strings = Db.VM.get_bios_strings ~__context ~self:vm in
  if current_strings <> [] then
    raise (Api_errors.Server_error (Api_errors.vm_bios_strings_already_set, []))
  else
    let bios_strings = Db.Host.get_bios_strings ~__context ~self:host in
    Db.VM.set_bios_strings ~__context ~self:vm ~value:bios_strings ;
    (* also set the affinity field to push the VM to start on this host *)
    Db.VM.set_affinity ~__context ~self:vm ~value:host

let consider_generic_bios_strings ~__context ~vm =
  (* check BIOS strings: set to generic values if empty *)
  let bios_strings = Db.VM.get_bios_strings ~__context ~self:vm in
  if bios_strings = [] then (
    info
      "The VM's BIOS strings were not yet filled in. The VM is now made \
       BIOS-generic." ;
    Db.VM.set_bios_strings ~__context ~self:vm
      ~value:Constants.generic_bios_strings
  )

(* Windows VM Generation ID *)

let fresh_genid ?(current_genid = "0:0") () =
  if current_genid = "" then
    ""
  else
    Printf.sprintf "%Ld:%Ld"
      (Random.int64 Int64.max_int)
      (Random.int64 Int64.max_int)

let vm_fresh_genid ~__context ~self =
  let current_genid = Db.VM.get_generation_id ~__context ~self in
  let new_genid = fresh_genid ~current_genid ()
  and uuid = Db.VM.get_uuid ~__context ~self in
  debug "Refreshing GenID for VM %s to %s" uuid new_genid ;
  Db.VM.set_generation_id ~__context ~self ~value:new_genid ;
  new_genid

(** Add to the VM's current operations, call a function and then remove from the
    	current operations. Ensure the allowed_operations are kept up to date. *)
let with_vm_operation ~__context ~self ~doc ~op ?(strict = true) ?policy f =
  let task_id = Ref.string_of (Context.get_task_id __context) in
  Helpers.retry_with_global_lock ~__context ~doc ?policy (fun () ->
      Xapi_vm_lifecycle.assert_operation_valid ~__context ~self ~op ~strict ;
      Db.VM.add_to_current_operations ~__context ~self ~key:task_id ~value:op ;
      Xapi_vm_lifecycle.update_allowed_operations ~__context ~self
  ) ;
  (* Then do the action with the lock released *)
  finally f (* Make sure to clean up at the end *) (fun () ->
      try
        Db.VM.remove_from_current_operations ~__context ~self ~key:task_id ;
        Xapi_vm_lifecycle.update_allowed_operations ~__context ~self ;
        Helpers.Early_wakeup.broadcast (Datamodel_common._vm, Ref.string_of self)
      with _ -> ()
  )

(* Device Model Profiles *)
let ensure_device_model_profile_present ~__context ~domain_type ~is_a_template
    ?(default_value = Vm_platform.fallback_device_model_default_value) platform
    =
  let needs_qemu = Helpers.needs_qemu_from_domain_type domain_type in
  let default = Vm_platform.(device_model, default_value) in
  let trad = Vm_platform.(device_model, fallback_device_model_stage_1) in
  if is_a_template then
    platform
  else if (not needs_qemu) || List.mem_assoc Vm_platform.device_model platform
  then (* upgrade existing Device Model entry *)
    platform |> List.map (fun entry -> if entry = trad then default else entry)
  else
    (* only add device-model to an HVM VM platform if it is not already there *)
    default :: platform
