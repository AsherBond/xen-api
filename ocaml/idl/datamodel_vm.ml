(* VM *)

open Datamodel_common
open Datamodel_roles
open Datamodel_types

let vmpp_removed =
  [
    (Lifecycle.Published, rel_cowley, "")
  ; (Deprecated, rel_clearwater, "Dummy transition")
  ; (Removed, rel_clearwater, "The VMPR feature was removed")
  ]

(* Removing a one-to-many field is quite difficult, leave vmpp reference
   deprecated only *)
let vmpp_deprecated =
  [
    (Lifecycle.Published, rel_cowley, "")
  ; (Deprecated, rel_clearwater, "The VMPR feature was removed")
  ]

let pv =
  [
    field
      ~lifecycle:[(Published, rel_rio, "name of or path to bootloader")]
      "bootloader" "name of or path to bootloader"
  ; field
      ~lifecycle:[(Published, rel_rio, "path to the kernel")]
      "kernel" "path to the kernel"
  ; field
      ~lifecycle:[(Published, rel_rio, "path to the initrd")]
      "ramdisk" "path to the initrd"
  ; field
      ~lifecycle:[(Published, rel_rio, "kernel command-line arguments")]
      "args" "kernel command-line arguments"
  ; field
      ~lifecycle:
        [(Published, rel_rio, "miscellaneous arguments for the bootloader")]
      "bootloader_args" "miscellaneous arguments for the bootloader"
  ; field ~in_oss_since:None
      ~lifecycle:[(Published, rel_rio, "to make Zurich guests boot")]
      "legacy_args" "to make Zurich guests boot"
  ]

(** HVM domain booting *)
let hvm =
  [
    field ~qualifier:StaticRO
      ~lifecycle:
        [
          (Published, rel_rio, "")
        ; (Deprecated, rel_kolkata, "Replaced by VM.domain_type")
        ]
      "boot_policy" "HVM boot policy"
  ; field
      ~lifecycle:[(Published, rel_rio, "HVM boot params")]
      ~ty:(Map (String, String))
      "boot_params" "HVM boot params"
  ; field ~writer_roles:_R_VM_POWER_ADMIN ~in_oss_since:None ~ty:Float
      ~lifecycle:
        [
          ( Published
          , rel_miami
          , "multiplier applied to the amount of shadow that will be made \
             available to the guest"
          )
        ]
      ~qualifier:StaticRO "shadow_multiplier"
      "multiplier applied to the amount of shadow that will be made available \
       to the guest"
      ~default_value:(Some (VFloat 1.))
  ]

let guest_memory =
  let field = field ~ty:Int in
  [
    field "overhead"
      ~lifecycle:
        [(Published, rel_rio, "Virtualization memory overhead (bytes).")]
      ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
      "Virtualization memory overhead (bytes)." ~default_value:(Some (VInt 0L))
      ~doc_tags:[Memory]
  ; field "target"
      ~lifecycle:
        [
          ( Published
          , rel_rio
          , "Dynamically-set memory target (bytes). The value of this field \
             indicates the current target for memory available to this VM."
          )
        ; (Deprecated, rel_midnight_ride, "")
        ]
      ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
      "Dynamically-set memory target (bytes). The value of this field \
       indicates the current target for memory available to this VM."
      ~default_value:(Some (VInt 0L)) ~doc_tags:[Memory]
  ; field "static_max"
      ~lifecycle:
        [
          ( Published
          , rel_rio
          , "Statically-set (i.e. absolute) maximum (bytes). The value of this \
             field at VM start time acts as a hard limit of the amount of \
             memory a guest can use. New values only take effect on reboot."
          )
        ]
      ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
      "Statically-set (i.e. absolute) maximum (bytes). The value of this field \
       at VM start time acts as a hard limit of the amount of memory a guest \
       can use. New values only take effect on reboot."
      ~doc_tags:[Memory]
  ; field "dynamic_max"
      ~lifecycle:[(Published, rel_rio, "Dynamic maximum (bytes)")]
      ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
      "Dynamic maximum (bytes)" ~doc_tags:[Memory]
  ; field "dynamic_min"
      ~lifecycle:[(Published, rel_rio, "Dynamic minimum (bytes)")]
      ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
      "Dynamic minimum (bytes)" ~doc_tags:[Memory]
  ; field "static_min"
      ~lifecycle:
        [
          ( Published
          , rel_rio
          , "Statically-set (i.e. absolute) mininum (bytes). The value of this \
             field indicates the least amount of memory this VM can boot with \
             without crashing."
          )
        ]
      ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
      "Statically-set (i.e. absolute) mininum (bytes). The value of this field \
       indicates the least amount of memory this VM can boot with without \
       crashing."
      ~doc_tags:[Memory]
  ]

(** Action to take on guest reboot/power off/sleep etc *)
let on_crash_behaviour =
  Enum
    ( "on_crash_behaviour"
    , [
        ("destroy", "destroy the VM state")
      ; ( "coredump_and_destroy"
        , "record a coredump and then destroy the VM state"
        )
      ; ("restart", "restart the VM")
      ; ("coredump_and_restart", "record a coredump and then restart the VM")
      ; ("preserve", "leave the crashed VM paused")
      ; ("rename_restart", "rename the crashed VM and start a new copy")
      ]
    )

let on_softreboot_behavior =
  Enum
    ( "on_softreboot_behavior"
    , [
        ("soft_reboot", "perform soft-reboot")
      ; ("destroy", "destroy the VM state")
      ; ("restart", "restart the VM")
      ; ("preserve", "leave the VM paused")
      ]
    )

let on_normal_exit_behaviour =
  Enum
    ( "on_normal_exit"
    , [("destroy", "destroy the VM state"); ("restart", "restart the VM")]
    )

(** Virtual CPUs *)
let vcpus =
  [
    field
      ~lifecycle:
        [
          ( Published
          , rel_rio
          , "configuration parameters for the selected VCPU policy"
          )
        ]
      ~ty:(Map (String, String))
      "params" "configuration parameters for the selected VCPU policy"
  ; field
      ~lifecycle:[(Published, rel_rio, "Max number of VCPUs")]
      ~qualifier:StaticRO ~ty:Int "max" "Max number of VCPUs"
  ; field
      ~lifecycle:[(Published, rel_rio, "Boot number of VCPUs")]
      ~qualifier:StaticRO ~ty:Int "at_startup" "Boot number of VCPUs"
  ]

(** Default actions *)
let actions =
  let crash name descr =
    field ~qualifier:StaticRO ~ty:on_crash_behaviour
      ~lifecycle:[(Published, rel_rio, descr)]
      name descr
  in
  let normal name descr =
    field ~ty:on_normal_exit_behaviour
      ~lifecycle:[(Published, rel_rio, descr)]
      name descr
  in
  let soft =
    field ~qualifier:RW ~lifecycle:[] ~ty:on_softreboot_behavior
      ~default_value:(Some (VEnum "soft_reboot"))
  in
  [
    soft "after_softreboot" "action to take after soft reboot"
  ; normal "after_shutdown" "action to take after the guest has shutdown itself"
  ; normal "after_reboot" "action to take after the guest has rebooted itself"
  ; crash "after_crash" "action to take if the guest crashes"
  ]

let set_actions_after_crash =
  call ~name:"set_actions_after_crash" ~in_oss_since:None
    ~lifecycle:[(Published, rel_rio, "Sets the actions_after_crash parameter")]
    ~doc:"Sets the actions_after_crash parameter"
    ~params:
      [
        (Ref _vm, "self", "The VM to set")
      ; (on_crash_behaviour, "value", "The new value to set")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let power_state =
  Enum
    ( "vm_power_state"
    , [
        ("Halted", "VM is offline and not using any resources")
      ; ( "Paused"
        , "All resources have been allocated but the VM itself is paused and \
           its vCPUs are not running"
        )
      ; ("Running", "Running")
      ; ( "Suspended"
        , "VM state has been saved to disk and it is nolonger running. Note \
           that disks remain in-use while the VM is suspended."
        )
      ]
    )

let get_boot_record =
  call ~name:"get_boot_record" ~in_oss_since:None
    ~lifecycle:
      [
        (Published, rel_rio, "")
      ; (Deprecated, rel_inverness, "Use the current VM record/fields instead")
      ]
    ~doc:
      "Returns a record describing the VM's dynamic state, initialised when \
       the VM boots and updated to reflect runtime configuration changes e.g. \
       CPU hotplug"
    ~result:(Record _vm, "A record describing the VM")
    ~params:[(Ref _vm, "self", "The VM whose boot-time state to return")]
    ~errs:[] ~flags:[`Session] (* no async *)
    ~allowed_roles:_R_READ_ONLY ()

let get_data_sources =
  call ~name:"get_data_sources" ~in_oss_since:None
    ~lifecycle:[(Published, rel_orlando, "")]
    ~doc:""
    ~result:(Set (Record _data_source), "A set of data sources")
    ~params:[(Ref _vm, "self", "The VM to interrogate")]
    ~errs:[] ~flags:[`Session] ~allowed_roles:_R_READ_ONLY ()

let record_data_source =
  call ~name:"record_data_source" ~in_oss_since:None
    ~lifecycle:
      [(Published, rel_orlando, "Start recording the specified data source")]
    ~doc:"Start recording the specified data source"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (String, "data_source", "The data source to record")
      ]
    ~errs:[] ~flags:[`Session] ~allowed_roles:_R_VM_ADMIN ()

let query_data_source =
  call ~name:"query_data_source" ~in_oss_since:None
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Query the latest value of the specified data source"
        )
      ]
    ~doc:"Query the latest value of the specified data source"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (String, "data_source", "The data source to query")
      ]
    ~result:(Float, "The latest value, averaged over the last 5 seconds")
    ~errs:[] ~flags:[`Session] ~allowed_roles:_R_READ_ONLY ()

let forget_data_source_archives =
  call ~name:"forget_data_source_archives" ~in_oss_since:None
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Forget the recorded statistics related to the specified data source"
        )
      ]
    ~doc:"Forget the recorded statistics related to the specified data source"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; ( String
        , "data_source"
        , "The data source whose archives are to be forgotten"
        )
      ]
    ~flags:[`Session] ~allowed_roles:_R_VM_ADMIN ()

let set_ha_always_run =
  call ~name:"set_ha_always_run" ~in_oss_since:None
    ~lifecycle:
      [
        (Published, rel_orlando, "Set the value of the ha_always_run")
      ; (Deprecated, rel_boston, "")
      ]
    ~doc:"Set the value of the ha_always_run"
    ~params:[(Ref _vm, "self", "The VM"); (Bool, "value", "The value")]
    ~flags:[`Session] ~allowed_roles:_R_POOL_OP ()

let set_ha_restart_priority =
  call ~name:"set_ha_restart_priority" ~in_oss_since:None
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Set the value of the ha_restart_priority field"
        )
      ]
    ~doc:"Set the value of the ha_restart_priority field"
    ~params:[(Ref _vm, "self", "The VM"); (String, "value", "The value")]
    ~flags:[`Session] ~allowed_roles:_R_POOL_OP ()

(* VM.Clone *)

let clone =
  call ~name:"clone"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Clones the specified VM, making a new VM. Clone automatically \
           exploits the capabilities of the underlying storage repository in \
           which the VM's disk images are stored (e.g. Copy on Write).   This \
           function can only be called when the VM is in the Halted State."
        )
      ]
    ~doc:
      "Clones the specified VM, making a new VM. Clone automatically exploits \
       the capabilities of the underlying storage repository in which the VM's \
       disk images are stored (e.g. Copy on Write).   This function can only \
       be called when the VM is in the Halted State."
    ~result:(Ref _vm, "The reference of the newly created VM.")
    ~params:
      [
        (Ref _vm, "vm", "The VM to be cloned")
      ; (String, "new_name", "The name of the cloned VM")
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.sr_full
      ; Api_errors.operation_not_allowed
      ; Api_errors.license_restriction
      ]
    ~allowed_roles:_R_VM_ADMIN ()

(* VM.Copy *)
let copy =
  call ~name:"copy"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Copies a VM to an SR. There must be a host that can see both the \
           source and destination SRs simultaneously"
        )
      ; ( Extended
        , rel_cowley
        , "The copy can now be performed between any two SRs."
        )
      ]
    ~doc:
      "Copied the specified VM, making a new VM. Unlike clone, copy does not \
       exploits the capabilities of the underlying storage repository in which \
       the VM's disk images are stored. Instead, copy guarantees that the disk \
       images of the newly created VM will be 'full disks' - i.e. not part of \
       a CoW chain.  This function can only be called when the VM is in the \
       Halted State."
    ~result:(Ref _vm, "The reference of the newly created VM.")
    ~params:
      [
        (Ref _vm, "vm", "The VM to be copied")
      ; (String, "new_name", "The name of the copied VM")
      ; ( Ref _sr
        , "sr"
        , "An SR to copy all the VM's disks into (if an invalid reference then \
           it uses the existing SRs)"
        )
      ]
    ~errs:(errnames_of_call clone) ~allowed_roles:_R_VM_ADMIN ()

(* VM.snapshot *)
let snapshot_with_quiesce =
  call ~name:"snapshot_with_quiesce"
    ~lifecycle:
      [
        (Published, rel_orlando, "")
      ; (Deprecated, rel_quebec, "Dummy transition")
      ; (Removed, rel_quebec, "VSS support has been removed")
      ]
    ~doc:
      "Snapshots the specified VM with quiesce, making a new VM. Snapshot \
       automatically exploits the capabilities of the underlying storage \
       repository in which the VM's disk images are stored (e.g. Copy on \
       Write)."
    ~result:(Ref _vm, "The reference of the newly created VM.")
    ~params:
      [
        (Ref _vm, "vm", "The VM to be snapshotted")
      ; (String, "new_name", "The name of the snapshotted VM")
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.sr_full
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_snapshot_with_quiesce_failed
      ; Api_errors.vm_snapshot_with_quiesce_timeout
      ; Api_errors.vm_snapshot_with_quiesce_plugin_does_not_respond
      ; Api_errors.vm_snapshot_with_quiesce_not_supported
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ()

let update_snapshot_metadata =
  call ~name:"update_snapshot_metadata"
    ~lifecycle:
      [(Published, rel_george, ""); (Deprecated, rel_midnight_ride, "")]
    ~doc:"" ~hide_from_docs:true
    ~params:
      [
        (Ref _vm, "vm", "The VM to update")
      ; (Ref _vm, "snapshot_of", "")
      ; ( DateTime
        , "snapshot_time"
        , "The timestamp the snapshot was taken. When a timezone is missing, \
           UTC is assumed"
        )
      ; (String, "transportable_snapshot_id", "")
      ]
    ~allowed_roles:_R_POOL_OP ()

let snapshot =
  call ~name:"snapshot"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Snapshots the specified VM, making a new VM. Snapshot automatically \
           exploits the capabilities of the underlying storage repository in \
           which the VM's disk images are stored (e.g. Copy on Write)."
        )
      ]
    ~doc:
      "Snapshots the specified VM, making a new VM. Snapshot automatically \
       exploits the capabilities of the underlying storage repository in which \
       the VM's disk images are stored (e.g. Copy on Write)."
    ~result:(Ref _vm, "The reference of the newly created VM.")
    ~versioned_params:
      [
        {
          param_type= Ref _vm
        ; param_name= "vm"
        ; param_doc= "The VM to be snapshotted"
        ; param_release= orlando_release
        ; param_default= None
        }
      ; {
          param_type= String
        ; param_name= "new_name"
        ; param_doc= "The name of the snapshotted VM"
        ; param_release= orlando_release
        ; param_default= None
        }
      ; {
          param_type= Set (Ref _vdi)
        ; param_name= "ignore_vdis"
        ; param_doc= "A list of VDIs to ignore for the snapshot"
        ; param_release= numbered_release "21.4.0"
        ; param_default= Some (VSet [])
        }
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.sr_full
      ; Api_errors.operation_not_allowed
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ~doc_tags:[Snapshots] ()

let revert =
  call ~name:"revert"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Reverts the specified VM to a previous state."
        )
      ]
    ~doc:"Reverts the specified VM to a previous state."
    ~params:[(Ref _vm, "snapshot", "The snapshotted state that we revert to")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.operation_not_allowed
      ; Api_errors.sr_full
      ; Api_errors.vm_revert_failed
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ~doc_tags:[Snapshots] ()

let checkpoint =
  call ~name:"checkpoint"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Checkpoints the specified VM, making a new VM. Checkpoint \
           automatically exploits the capabilities of the underlying storage \
           repository in which the VM's disk images are stored (e.g. Copy on \
           Write) and saves the memory image as well."
        )
      ]
    ~doc:
      "Checkpoints the specified VM, making a new VM. Checkpoint automatically \
       exploits the capabilities of the underlying storage repository in which \
       the VM's disk images are stored (e.g. Copy on Write) and saves the \
       memory image as well."
    ~result:(Ref _vm, "The reference of the newly created VM.")
    ~params:
      [
        (Ref _vm, "vm", "The VM to be checkpointed")
      ; (String, "new_name", "The name of the checkpointed VM")
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.sr_full
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_checkpoint_suspend_failed
      ; Api_errors.vm_checkpoint_resume_failed
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ()

let create_template =
  call ~name:"create_template" ~hide_from_docs:true
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Deprecated: use VM.clone or VM.copy instead."
        )
      ; (Deprecated, rel_midnight_ride, "")
      ]
    ~doc:"Deprecated: use VM.clone or VM.copy instead." ~result:(Ref _vm, "")
    ~params:[(Ref _vm, "vm", ""); (String, "new_name", "")]
    ~errs:[] ~allowed_roles:_R_VM_ADMIN ()

let set_is_default_template =
  call ~name:"set_is_default_template" ~hide_from_docs:true
    ~lifecycle:[(Published, rel_falcon, "Allows to define default templates")]
    ~doc:"Makes the specified VM a default template."
    ~params:
      [
        (Ref _vm, "vm", "The VM that will become a default template")
      ; (Bool, "value", "The boolean value for the is_default_template flag")
      ]
    ~errs:[] ~allowed_roles:_R_POOL_ADMIN ()

let import_convert =
  call ~name:"import_convert"
    ~lifecycle:[(Published, rel_tampa, "Import using a conversion service.")]
    ~doc:"Import using a conversion service."
    ~params:
      [
        (String, "type", "Type of the conversion")
      ; (String, "username", "Admin username on the host")
      ; (String, "password", "Password on the host")
      ; (Ref _sr, "sr", "The destination SR")
      ; (Map (String, String), "remote_config", "Remote configuration options")
      ]
    ~errs:[] ~allowed_roles:_R_VM_ADMIN ()

(* VM.Provision -- causes the template's disks to be instantiated *)

let provision =
  call ~name:"provision"
    ~doc:
      "Inspects the disk configuration contained within the VM's other_config, \
       creates VDIs and VBDs and then executes any applicable post-install \
       script."
    ~params:[(Ref _vm, "vm", "The VM to be provisioned")]
    ~in_oss_since:None
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Inspects the disk configuration contained within the VM's \
           other_config, creates VDIs and VBDs and then executes any \
           applicable post-install script."
        )
      ]
    ~errs:(errnames_of_call clone) ~allowed_roles:_R_VM_ADMIN ()

(* VM.Start *)

let start =
  call ~name:"start"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Start the specified VM.  This function can only be called with the \
           VM is in the Halted State."
        )
      ]
    ~doc:
      "Start the specified VM.  This function can only be called with the VM \
       is in the Halted State."
    ~params:
      [
        (Ref _vm, "vm", "The VM to start")
      ; (Bool, "start_paused", "Instantiate VM in paused state if set to true.")
      ; ( Bool
        , "force"
        , "Attempt to force the VM to start. If this flag is false then the VM \
           may fail pre-boot safety checks (e.g. if the CPU the VM last booted \
           on looks substantially different to the current one)"
        )
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.vm_hvm_required
      ; Api_errors.vm_is_template
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.bootloader_failed
      ; Api_errors.unknown_bootloader
      ; Api_errors.no_hosts_available
      ; Api_errors.license_restriction
      ]
    ~allowed_roles:_R_VM_OP ()

let assert_can_boot_here =
  call ~name:"assert_can_boot_here"
    ~lifecycle:
      [
        (Published, rel_rio, "")
      ; ( Changed
        , rel_quebec
        , "Does additional compatibility checks when VM powerstate is not \
           halted (e.g. CPUID). Use this before calling VM.resume or \
           VM.pool_migrate."
        )
      ]
    ~doc:
      "Returns an error if the VM could not boot on this host for some reason"
    ~params:[(Ref _vm, "self", "The VM"); (Ref _host, "host", "The host")]
    ~allowed_roles:_R_READ_ONLY
    ~errs:
      [
        Api_errors.host_not_enough_free_memory
      ; Api_errors.host_not_enough_pcpus
      ; Api_errors.network_sriov_insufficient_capacity
      ; Api_errors.host_not_live
      ; Api_errors.host_disabled
      ; Api_errors.host_cannot_attach_network
      ; Api_errors.vm_hvm_required
      ; Api_errors.vm_requires_gpu
      ; Api_errors.vm_requires_iommu
      ; Api_errors.vm_requires_net
      ; Api_errors.vm_requires_sr
      ; Api_errors.vm_requires_vgpu
      ; Api_errors.vm_host_incompatible_version
      ; Api_errors.vm_host_incompatible_virtual_hardware_platform_version
      ; Api_errors.invalid_value
      ; Api_errors.memory_constraint_violation
      ; Api_errors.operation_not_allowed
      ; Api_errors.value_not_supported
      ; Api_errors.vm_incompatible_with_this_host
      ]
    ~doc_tags:[Memory] ()

let assert_agile =
  call ~name:"assert_agile"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Returns an error if the VM is not considered agile e.g. because it \
           is tied to a resource local to a host"
        )
      ]
    ~doc:
      "Returns an error if the VM is not considered agile e.g. because it is \
       tied to a resource local to a host"
    ~params:[(Ref _vm, "self", "The VM")]
    ~allowed_roles:_R_READ_ONLY ()

let get_possible_hosts =
  call ~name:"get_possible_hosts"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Return the list of hosts on which this VM may run."
        )
      ]
    ~doc:"Return the list of hosts on which this VM may run."
    ~params:[(Ref _vm, "vm", "The VM")]
    ~result:(Set (Ref _host), "The possible hosts")
    ~allowed_roles:_R_READ_ONLY ()

let retrieve_wlb_recommendations =
  call ~name:"retrieve_wlb_recommendations"
    ~lifecycle:
      [
        ( Published
        , rel_george
        , "Returns mapping of hosts to ratings, indicating the suitability of \
           starting the VM at that location according to wlb. Rating is \
           replaced with an error if the VM cannot boot there."
        )
      ]
    ~doc:
      "Returns mapping of hosts to ratings, indicating the suitability of \
       starting the VM at that location according to wlb. Rating is replaced \
       with an error if the VM cannot boot there."
    ~params:[(Ref _vm, "vm", "The VM")]
    ~result:
      ( Map (Ref _host, Set String)
      , "The potential hosts and their corresponding recommendations or errors"
      )
    ~allowed_roles:_R_READ_ONLY ()

let maximise_memory =
  call
    ~lifecycle:
      [
        ( Published
        , rel_miami
        , "Returns the maximum amount of guest memory which will fit, together \
           with overheads, in the supplied amount of physical memory. If \
           'exact' is true then an exact calculation is performed using the \
           VM's current settings. If 'exact' is false then a more conservative \
           approximation is used"
        )
      ]
    ~name:"maximise_memory"
    ~doc:
      "Returns the maximum amount of guest memory which will fit, together \
       with overheads, in the supplied amount of physical memory. If 'exact' \
       is true then an exact calculation is performed using the VM's current \
       settings. If 'exact' is false then a more conservative approximation is \
       used"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "total", "Total amount of physical RAM to fit within")
      ; ( Bool
        , "approximate"
        , "If false the limit is calculated with the guest's current exact \
           configuration. Otherwise a more approximate calculation is \
           performed"
        )
      ]
    ~result:(Int, "The maximum possible static-max")
    ~allowed_roles:_R_READ_ONLY ~doc_tags:[Memory] ()

let get_allowed_VBD_devices =
  call ~flags:[`Session] ~no_current_operations:true
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Returns a list of the allowed values that a VBD device field can \
           take"
        )
      ]
    ~name:"get_allowed_VBD_devices"
    ~doc:"Returns a list of the allowed values that a VBD device field can take"
    ~params:[(Ref _vm, "vm", "The VM to query")]
    ~result:(Set String, "The allowed values")
    ~allowed_roles:_R_READ_ONLY ()

let get_allowed_VIF_devices =
  call ~flags:[`Session] ~no_current_operations:true
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Returns a list of the allowed values that a VIF device field can \
           take"
        )
      ]
    ~name:"get_allowed_VIF_devices"
    ~doc:"Returns a list of the allowed values that a VIF device field can take"
    ~params:[(Ref _vm, "vm", "The VM to query")]
    ~result:(Set String, "The allowed values")
    ~allowed_roles:_R_READ_ONLY ()

(* VM.atomic_set_resident_on *)
(* an internal call that sets resident_on and clears the scheduled_to_be_resident_on atomically *)

let atomic_set_resident_on =
  call
    ~lifecycle:[(Published, rel_rio, "")]
    ~pool_internal:true ~hide_from_docs:true ~name:"atomic_set_resident_on"
    ~doc:""
    ~params:
      [
        (Ref _vm, "vm", "The VM to modify")
      ; (Ref _host, "host", "The host to set resident_on to")
      ]
    ~allowed_roles:_R_LOCAL_ROOT_ONLY ()

let compute_memory_overhead =
  call
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Computes the virtualization memory overhead of a VM."
        )
      ]
    ~name:"compute_memory_overhead"
    ~doc:"Computes the virtualization memory overhead of a VM."
    ~params:[(Ref _vm, "vm", "The VM for which to compute the memory overhead")]
    ~pool_internal:false ~hide_from_docs:false
    ~result:(Int, "the virtualization memory overhead of the VM.")
    ~allowed_roles:_R_READ_ONLY ~doc_tags:[Memory] ()

let set_memory_dynamic_max =
  call ~flags:[`Session]
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the value of the memory_dynamic_max field"
        )
      ]
    ~name:"set_memory_dynamic_max"
    ~doc:"Set the value of the memory_dynamic_max field"
    ~params:
      [
        (Ref _vm, "self", "The VM to modify")
      ; (Int, "value", "The new value of memory_dynamic_max")
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ~errs:[] ~doc_tags:[Memory] ()

let set_memory_dynamic_min =
  call ~flags:[`Session]
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the value of the memory_dynamic_min field"
        )
      ]
    ~name:"set_memory_dynamic_min"
    ~doc:"Set the value of the memory_dynamic_min field"
    ~params:
      [
        (Ref _vm, "self", "The VM to modify")
      ; (Int, "value", "The new value of memory_dynamic_min")
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ~errs:[] ~doc_tags:[Memory] ()

let set_memory_dynamic_range =
  call ~name:"set_memory_dynamic_range"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the minimum and maximum amounts of physical memory the VM is \
           allowed to use."
        )
      ]
    ~doc:
      "Set the minimum and maximum amounts of physical memory the VM is \
       allowed to use."
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "min", "The new minimum value")
      ; (Int, "max", "The new maximum value")
      ]
    ~doc_tags:[Memory] ()

(* When HA is enabled we need to prevent memory *)
(* changes which will break the recovery plan.  *)
let set_memory_static_max =
  call ~flags:[`Session]
    ~lifecycle:
      [(Published, rel_orlando, "Set the value of the memory_static_max field")]
    ~name:"set_memory_static_max"
    ~doc:"Set the value of the memory_static_max field"
    ~errs:[Api_errors.ha_operation_would_break_failover_plan]
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [
        (Ref _vm, "self", "The VM to modify")
      ; (Int, "value", "The new value of memory_static_max")
      ]
    ~doc_tags:[Memory] ()

let set_memory_static_min =
  call ~flags:[`Session]
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the value of the memory_static_min field"
        )
      ]
    ~name:"set_memory_static_min"
    ~doc:"Set the value of the memory_static_min field" ~errs:[]
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [
        (Ref _vm, "self", "The VM to modify")
      ; (Int, "value", "The new value of memory_static_min")
      ]
    ~doc_tags:[Memory] ()

let set_memory_static_range =
  call ~name:"set_memory_static_range"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the static (ie boot-time) range of virtual memory that the VM \
           is allowed to use."
        )
      ]
    ~doc:
      "Set the static (ie boot-time) range of virtual memory that the VM is \
       allowed to use."
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "min", "The new minimum value")
      ; (Int, "max", "The new maximum value")
      ]
    ~doc_tags:[Memory] ()

let set_memory_limits =
  call ~name:"set_memory_limits"
    ~lifecycle:
      [(Published, rel_midnight_ride, "Set the memory limits of this VM.")]
    ~doc:"Set the memory limits of this VM." ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "static_min", "The new value of memory_static_min.")
      ; (Int, "static_max", "The new value of memory_static_max.")
      ; (Int, "dynamic_min", "The new value of memory_dynamic_min.")
      ; (Int, "dynamic_max", "The new value of memory_dynamic_max.")
      ]
    ~doc_tags:[Memory] ()

let set_memory =
  call ~name:"set_memory"
    ~lifecycle:
      [
        ( Published
        , rel_ely
        , "Set the memory allocation of this VM. Sets all of \
           memory_static_max, memory_dynamic_min, and memory_dynamic_max to \
           the given value, and leaves memory_static_min untouched."
        )
      ]
    ~doc:
      "Set the memory allocation of this VM. Sets all of memory_static_max, \
       memory_dynamic_min, and memory_dynamic_max to the given value, and \
       leaves memory_static_min untouched."
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "value", "The new memory allocation (bytes).")
      ]
    ~doc_tags:[Memory] ()

let set_memory_target_live =
  call ~name:"set_memory_target_live"
    ~lifecycle:
      [
        (Published, rel_rio, "Set the memory target for a running VM")
      ; (Deprecated, rel_midnight_ride, "")
      ]
    ~doc:"Set the memory target for a running VM"
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~params:
      [(Ref _vm, "self", "The VM"); (Int, "target", "The target in bytes")]
    ~doc_tags:[Memory] ()

let wait_memory_target_live =
  call ~name:"wait_memory_target_live"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Wait for a running VM to reach its current memory target"
        )
      ; (Deprecated, rel_midnight_ride, "")
      ]
    ~doc:"Wait for a running VM to reach its current memory target"
    ~allowed_roles:_R_READ_ONLY
    ~params:[(Ref _vm, "self", "The VM")]
    ~doc_tags:[Memory] ()

let get_cooperative =
  call ~name:"get_cooperative"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Return true if the VM is currently 'co-operative' i.e. is expected \
           to reach a balloon target and actually has done"
        )
      ; (Deprecated, rel_tampa, "")
      ]
    ~doc:
      "Return true if the VM is currently 'co-operative' i.e. is expected to \
       reach a balloon target and actually has done"
    ~params:[(Ref _vm, "self", "The VM")]
    ~result:(Bool, "true if the VM is currently 'co-operative'; false otherwise")
    ~allowed_roles:_R_READ_ONLY ~doc_tags:[Memory] ()

let query_services =
  call ~name:"query_services"
    ~lifecycle:
      [
        ( Published
        , rel_tampa
        , "Query the system services advertised by this VM and register them. \
           This can only be applied to a system domain."
        )
      ]
    ~doc:
      "Query the system services advertised by this VM and register them. This \
       can only be applied to a system domain."
    ~params:[(Ref _vm, "self", "The VM")]
    ~result:(Map (String, String), "map of service type to name")
    ~allowed_roles:_R_POOL_ADMIN ()

(* VM.StartOn *)

let start_on =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Start the specified VM on a particular host.  This function can \
           only be called with the VM is in the Halted State."
        )
      ]
    ~name:"start_on"
    ~doc:
      "Start the specified VM on a particular host.  This function can only be \
       called with the VM is in the Halted State."
    ~in_oss_since:None
    ~params:
      [
        (Ref _vm, "vm", "The VM to start")
      ; (Ref _host, "host", "The Host on which to start the VM")
      ; (Bool, "start_paused", "Instantiate VM in paused state if set to true.")
      ; ( Bool
        , "force"
        , "Attempt to force the VM to start. If this flag is false then the VM \
           may fail pre-boot safety checks (e.g. if the CPU the VM last booted \
           on looks substantially different to the current one)"
        )
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.vm_is_template
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.bootloader_failed
      ; Api_errors.unknown_bootloader
      ]
    ~allowed_roles:(_R_VM_POWER_ADMIN ++ _R_CLIENT_CERT)
    ()

(* VM.Pause *)

let pause =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Pause the specified VM. This can only be called when the specified \
           VM is in the Running state."
        )
      ]
    ~name:"pause"
    ~doc:
      "Pause the specified VM. This can only be called when the specified VM \
       is in the Running state."
    ~params:[(Ref _vm, "vm", "The VM to pause")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

(* VM.UnPause *)

let unpause =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Resume the specified VM. This can only be called when the specified \
           VM is in the Paused state."
        )
      ]
    ~name:"unpause"
    ~doc:
      "Resume the specified VM. This can only be called when the specified VM \
       is in the Paused state."
    ~params:[(Ref _vm, "vm", "The VM to unpause")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

(* VM.CleanShutdown *)

let cleanShutdown =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Attempt to cleanly shutdown the specified VM. (Note: this may not \
           be supported---e.g. if a guest agent is not installed). This can \
           only be called when the specified VM is in the Running state."
        )
      ]
    ~name:"clean_shutdown"
    ~doc:
      "Attempt to cleanly shutdown the specified VM. (Note: this may not be \
       supported---e.g. if a guest agent is not installed). This can only be \
       called when the specified VM is in the Running state."
    ~params:[(Ref _vm, "vm", "The VM to shutdown")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

(* VM.CleanReboot *)

let cleanReboot =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Attempt to cleanly shutdown the specified VM (Note: this may not be \
           supported---e.g. if a guest agent is not installed). This can only \
           be called when the specified VM is in the Running state."
        )
      ]
    ~name:"clean_reboot"
    ~doc:
      "Attempt to cleanly shutdown the specified VM (Note: this may not be \
       supported---e.g. if a guest agent is not installed). This can only be \
       called when the specified VM is in the Running state."
    ~params:[(Ref _vm, "vm", "The VM to shutdown")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

(* VM.HardShutdown *)

let hardShutdown =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Stop executing the specified VM without attempting a clean shutdown."
        )
      ]
    ~name:"hard_shutdown"
    ~doc:"Stop executing the specified VM without attempting a clean shutdown."
    ~params:[(Ref _vm, "vm", "The VM to destroy")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

(* VM.Shutdown *)

let shutdown =
  call
    ~lifecycle:
      [
        ( Published
        , rel_clearwater
        , "Attempts to first clean shutdown a VM and if it should fail then \
           perform a hard shutdown on it."
        )
      ]
    ~name:"shutdown"
    ~doc:
      "Attempts to first clean shutdown a VM and if it should fail then \
       perform a hard shutdown on it."
    ~params:[(Ref _vm, "vm", "The VM to shutdown")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:(_R_VM_OP ++ _R_CLIENT_CERT)
    ()

(* VM.PowerStateReset *)

let stateReset =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Reset the power-state of the VM to halted in the database only. \
           (Used to recover from slave failures in pooling scenarios by \
           resetting the power-states of VMs running on dead slaves to \
           halted.) This is a potentially dangerous operation; use with care."
        )
      ]
    ~name:"power_state_reset"
    ~doc:
      "Reset the power-state of the VM to halted in the database only. (Used \
       to recover from slave failures in pooling scenarios by resetting the \
       power-states of VMs running on dead slaves to halted.) This is a \
       potentially dangerous operation; use with care."
    ~params:[(Ref _vm, "vm", "The VM to reset")]
    ~errs:[] ~allowed_roles:_R_POOL_OP ()

(* VM.HardReboot *)

let hardReboot =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Stop executing the specified VM without attempting a clean shutdown \
           and immediately restart the VM."
        )
      ]
    ~name:"hard_reboot"
    ~doc:
      "Stop executing the specified VM without attempting a clean shutdown and \
       immediately restart the VM."
    ~params:[(Ref _vm, "vm", "The VM to reboot")]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

let hardReboot_internal =
  call
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Internal function which immediately restarts the specified VM."
        )
      ; (Deprecated, rel_midnight_ride, "")
      ]
    ~name:"hard_reboot_internal"
    ~doc:"Internal function which immediately restarts the specified VM."
    ~params:[(Ref _vm, "vm", "The VM to reboot")]
    ~pool_internal:true ~hide_from_docs:true ~allowed_roles:_R_LOCAL_ROOT_ONLY
    ()

(* VM.Hibernate *)

let suspend =
  call
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Suspend the specified VM to disk.  This can only be called when the \
           specified VM is in the Running state."
        )
      ]
    ~name:"suspend"
    ~doc:
      "Suspend the specified VM to disk.  This can only be called when the \
       specified VM is in the Running state."
    ~params:[(Ref _vm, "vm", "The VM to suspend")]
      (*	    Bool, "live", "If set to true, perform a live hibernate; otherwise suspend the VM before commencing hibernate" *)
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:(_R_VM_OP ++ _R_CLIENT_CERT)
    ()

(* VM.clsp -- clone suspended, undocumented API for VMLogix *)
let csvm =
  call ~name:"csvm"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "undocumented. internal use only. This call is deprecated."
        )
      ; (Deprecated, rel_miami, "")
      ]
    ~doc:"undocumented. internal use only. This call is deprecated."
    ~params:[(Ref _vm, "vm", "")]
    ~result:(Ref _vm, "") ~errs:(errnames_of_call clone) ~hide_from_docs:true
    ~allowed_roles:_R_VM_ADMIN ()

(* VM.UnHibernate *)

let resume =
  call ~name:"resume"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Awaken the specified VM and resume it.  This can only be called \
           when the specified VM is in the Suspended state."
        )
      ]
    ~doc:
      "Awaken the specified VM and resume it.  This can only be called when \
       the specified VM is in the Suspended state."
    ~params:
      [
        (Ref _vm, "vm", "The VM to resume")
      ; (Bool, "start_paused", "Resume VM in paused state if set to true.")
      ; ( Bool
        , "force"
        , "Attempt to force the VM to resume. If this flag is false then the \
           VM may fail pre-resume safety checks (e.g. if the CPU the VM was \
           running on looks substantially different to the current one)"
        )
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:_R_VM_OP ()

let resume_on =
  call ~name:"resume_on"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Awaken the specified VM and resume it on a particular Host.  This \
           can only be called when the specified VM is in the Suspended state."
        )
      ]
    ~doc:
      "Awaken the specified VM and resume it on a particular Host.  This can \
       only be called when the specified VM is in the Suspended state."
    ~in_oss_since:None
    ~params:
      [
        (Ref _vm, "vm", "The VM to resume")
      ; (Ref _host, "host", "The Host on which to resume the VM")
      ; (Bool, "start_paused", "Resume VM in paused state if set to true.")
      ; ( Bool
        , "force"
        , "Attempt to force the VM to resume. If this flag is false then the \
           VM may fail pre-resume safety checks (e.g. if the CPU the VM was \
           running on looks substantially different to the current one)"
        )
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_is_template
      ]
    ~allowed_roles:(_R_VM_POWER_ADMIN ++ _R_CLIENT_CERT)
    ()

let pool_migrate =
  call ~in_oss_since:None
    ~lifecycle:[(Published, rel_rio, "Migrate a VM to another Host.")]
    ~name:"pool_migrate" ~doc:"Migrate a VM to another Host."
    ~params:
      [
        (Ref _vm, "vm", "The VM to migrate")
      ; (Ref _host, "host", "The target host")
      ; ( Map (String, String)
        , "options"
        , "Extra configuration operations: force, live, copy, compress. Each \
           is a boolean option, taking 'true' or 'false' as a value. Option \
           'compress' controls the use of stream compression during migration."
        )
      ]
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.vm_is_template
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_bad_power_state
      ]
    ~allowed_roles:(_R_VM_POWER_ADMIN ++ _R_CLIENT_CERT)
    ()

let pool_migrate_complete =
  call ~in_oss_since:None
    ~lifecycle:
      [
        ( Published
        , rel_tampa
        , "Tell a destination host that migration is complete."
        )
      ]
    ~name:"pool_migrate_complete"
    ~doc:"Tell a destination host that migration is complete."
    ~params:
      [
        (Ref _vm, "vm", "The VM which has finished migrating")
      ; (Ref _host, "host", "The target host")
      ]
    ~hide_from_docs:true
    ~pool_internal:false (* needed for cross-pool migrate too *)
    ~allowed_roles:(_R_VM_POWER_ADMIN ++ _R_CLIENT_CERT)
    ()

let set_vcpus_number_live =
  call ~name:"set_VCPUs_number_live"
    ~lifecycle:
      [
        (Published, rel_rio, "Set the number of VCPUs for a running VM")
      ; ( Changed
        , rel_ely
        , "Unless the feature is explicitly enabled for every host in the \
           pool, this fails with Api_errors.license_restriction."
        )
      ]
    ~doc:"Set the number of VCPUs for a running VM"
    ~params:[(Ref _vm, "self", "The VM"); (Int, "nvcpu", "The number of VCPUs")]
    ~allowed_roles:_R_VM_ADMIN
    ~errs:[Api_errors.operation_not_allowed; Api_errors.license_restriction]
    ()

let set_VCPUs_max =
  call ~flags:[`Session] ~name:"set_VCPUs_max"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the maximum number of VCPUs for a halted VM"
        )
      ]
    ~doc:"Set the maximum number of VCPUs for a halted VM"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "value", "The new maximum number of VCPUs")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let set_VCPUs_at_startup =
  call ~flags:[`Session] ~name:"set_VCPUs_at_startup"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the number of startup VCPUs for a halted VM"
        )
      ]
    ~doc:"Set the number of startup VCPUs for a halted VM"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "value", "The new maximum number of VCPUs")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let set_HVM_shadow_multiplier =
  call ~flags:[`Session] ~name:"set_HVM_shadow_multiplier"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Set the shadow memory multiplier on a halted VM"
        )
      ]
    ~doc:"Set the shadow memory multiplier on a halted VM"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Float, "value", "The new shadow memory multiplier to set")
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ()

let set_shadow_multiplier_live =
  call ~name:"set_shadow_multiplier_live"
    ~lifecycle:
      [(Published, rel_rio, "Set the shadow memory multiplier on a running VM")]
    ~doc:"Set the shadow memory multiplier on a running VM"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Float, "multiplier", "The new shadow memory multiplier to set")
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ()

let add_to_VCPUs_params_live =
  call ~name:"add_to_VCPUs_params_live"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Add the given key-value pair to VM.VCPUs_params, and apply that \
           value on the running VM"
        )
      ]
    ~doc:
      "Add the given key-value pair to VM.VCPUs_params, and apply that value \
       on the running VM"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (String, "key", "The key")
      ; (String, "value", "The value")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let remove_from_NVRAM =
  call ~flags:[`Session] ~name:"remove_from_NVRAM"
    ~lifecycle:[(Published, rel_naples, "")]
    ~params:[(Ref _vm, "self", "The VM"); (String, "key", "The key")]
    ~allowed_roles:_R_VM_ADMIN ()

let add_to_NVRAM =
  call ~flags:[`Session] ~name:"add_to_NVRAM"
    ~lifecycle:[(Published, rel_naples, "")]
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (String, "key", "The key")
      ; (String, "value", "The value")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let set_NVRAM =
  call ~flags:[`Session] ~name:"set_NVRAM"
    ~lifecycle:[(Published, rel_naples, "")]
    ~params:
      [
        (Ref _vm, "self", "The VM"); (Map (String, String), "value", "The value")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let send_sysrq =
  call ~name:"send_sysrq"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Send the given key as a sysrq to this VM.  The key is specified as \
           a single character (a String of length 1).  This can only be called \
           when the specified VM is in the Running state."
        )
      ]
    ~doc:
      "Send the given key as a sysrq to this VM.  The key is specified as a \
       single character (a String of length 1).  This can only be called when \
       the specified VM is in the Running state."
    ~params:[(Ref _vm, "vm", "The VM"); (String, "key", "The key to send")]
    ~errs:[Api_errors.vm_bad_power_state]
    ~allowed_roles:_R_POOL_ADMIN ()

let send_trigger =
  call ~name:"send_trigger"
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Send the named trigger to this VM.  This can only be called when \
           the specified VM is in the Running state."
        )
      ]
    ~doc:
      "Send the named trigger to this VM.  This can only be called when the \
       specified VM is in the Running state."
    ~params:
      [(Ref _vm, "vm", "The VM"); (String, "trigger", "The trigger to send")]
    ~errs:[Api_errors.vm_bad_power_state]
    ~allowed_roles:_R_POOL_ADMIN ()

let migrate_send =
  call ~name:"migrate_send"
    ~lifecycle:
      [
        ( Published
        , rel_tampa
        , "Migrate the VM to another host.  This can only be called when the \
           specified VM is in the Running state."
        )
      ]
    ~doc:
      "Migrate the VM to another host.  This can only be called when the \
       specified VM is in the Running state."
    ~versioned_params:
      [
        {
          param_type= Ref _vm
        ; param_name= "vm"
        ; param_doc= "The VM"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (String, String)
        ; param_name= "dest"
        ; param_doc= "The result of a Host.migrate_receive call."
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Bool
        ; param_name= "live"
        ; param_doc= "Live migration"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (Ref _vdi, Ref _sr)
        ; param_name= "vdi_map"
        ; param_doc= "Map of source VDI to destination SR"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (Ref _vif, Ref _network)
        ; param_name= "vif_map"
        ; param_doc= "Map of source VIF to destination network"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (String, String)
        ; param_name= "options"
        ; param_doc= "Other parameters"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (Ref _vgpu, Ref _gpu_group)
        ; param_name= "vgpu_map"
        ; param_doc= "Map of source vGPU to destination GPU group"
        ; param_release= inverness_release
        ; param_default= Some (VMap [])
        }
      ]
    ~result:
      (Ref _vm, "The reference of the newly created VM in the destination pool")
    ~errs:[Api_errors.vm_bad_power_state; Api_errors.license_restriction]
    ~allowed_roles:_R_VM_POWER_ADMIN ()

let assert_can_migrate =
  call ~name:"assert_can_migrate"
    ~lifecycle:
      [
        ( Published
        , rel_tampa
        , "Assert whether a VM can be migrated to the specified destination."
        )
      ]
    ~doc:"Assert whether a VM can be migrated to the specified destination."
    ~versioned_params:
      [
        {
          param_type= Ref _vm
        ; param_name= "vm"
        ; param_doc= "The VM"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (String, String)
        ; param_name= "dest"
        ; param_doc= "The result of a VM.migrate_receive call."
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Bool
        ; param_name= "live"
        ; param_doc= "Live migration"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (Ref _vdi, Ref _sr)
        ; param_name= "vdi_map"
        ; param_doc= "Map of source VDI to destination SR"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (Ref _vif, Ref _network)
        ; param_name= "vif_map"
        ; param_doc= "Map of source VIF to destination network"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (String, String)
        ; param_name= "options"
        ; param_doc= "Other parameters"
        ; param_release= tampa_release
        ; param_default= None
        }
      ; {
          param_type= Map (Ref _vgpu, Ref _gpu_group)
        ; param_name= "vgpu_map"
        ; param_doc= "Map of source vGPU to destination GPU group"
        ; param_release= inverness_release
        ; param_default= Some (VMap [])
        }
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN
    ~errs:[Api_errors.license_restriction]
    ()

let assert_can_migrate_sender =
  call ~name:"assert_can_migrate_sender"
    ~lifecycle:[(Published, rel_inverness, "")]
    ~doc:
      "Assertions for VM.assert_can_migrate that must be done on the sending \
       host."
    ~params:
      [
        (Ref _vm, "vm", "The VM")
      ; ( Map (String, String)
        , "dest"
        , "The result of a VM.migrate_receive call."
        )
      ; (Bool, "live", "Live migration")
      ; ( Map (Ref _vdi, Ref _sr)
        , "vdi_map"
        , "Map of source VDI to destination SR"
        )
      ; ( Map (Ref _vif, Ref _network)
        , "vif_map"
        , "Map of source VIF to destination network"
        )
      ; ( Map (Ref _vgpu, Ref _gpu_group)
        , "vgpu_map"
        , "Map of source vGPU to destination GPU group"
        )
      ; (Map (String, String), "options", "Other parameters")
      ]
    ~allowed_roles:_R_VM_POWER_ADMIN ~hide_from_docs:true ()

let s3_suspend =
  call ~name:"s3_suspend"
    ~lifecycle:
      [(Published, rel_midnight_ride, "Try to put the VM into ACPI S3 state")]
    ~doc:"Try to put the VM into ACPI S3 state"
    ~params:[(Ref _vm, "vm", "The VM")]
    ~hide_from_docs:true ~allowed_roles:_R_VM_OP ()

let s3_resume =
  call ~name:"s3_resume"
    ~lifecycle:
      [
        (Published, rel_midnight_ride, "Try to resume the VM from ACPI S3 state")
      ]
    ~doc:"Try to resume the VM from ACPI S3 state"
    ~params:[(Ref _vm, "vm", "The VM")]
    ~hide_from_docs:true ~allowed_roles:_R_VM_OP ()

let create_new_blob =
  call ~name:"create_new_blob"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Create a placeholder for a named binary blob of data that is \
           associated with this VM"
        )
      ]
    ~doc:
      "Create a placeholder for a named binary blob of data that is associated \
       with this VM"
    ~versioned_params:
      [
        {
          param_type= Ref _vm
        ; param_name= "vm"
        ; param_doc= "The VM"
        ; param_release= orlando_release
        ; param_default= None
        }
      ; {
          param_type= String
        ; param_name= "name"
        ; param_doc= "The name associated with the blob"
        ; param_release= orlando_release
        ; param_default= None
        }
      ; {
          param_type= String
        ; param_name= "mime_type"
        ; param_doc=
            "The mime type for the data. Empty string translates to \
             application/octet-stream"
        ; param_release= orlando_release
        ; param_default= None
        }
      ; {
          param_type= Bool
        ; param_name= "public"
        ; param_doc= "True if the blob should be publicly available"
        ; param_release= tampa_release
        ; param_default= Some (VBool false)
        }
      ]
    ~result:
      (Ref _blob, "The reference of the blob, needed for populating its data")
    ~allowed_roles:_R_VM_POWER_ADMIN ()

let set_bios_strings =
  call ~name:"set_bios_strings"
    ~lifecycle:
      [
        ( Published
        , rel_inverness
        , "Set custom BIOS strings to this VM. VM will be given a default set \
           of BIOS strings, only some of which can be overridden by the \
           supplied values. Allowed keys are: 'bios-vendor', 'bios-version', \
           'system-manufacturer', 'system-product-name', 'system-version', \
           'system-serial-number', 'enclosure-asset-tag', \
           'baseboard-manufacturer', 'baseboard-product-name', \
           'baseboard-version', 'baseboard-serial-number', \
           'baseboard-asset-tag', 'baseboard-location-in-chassis', \
           'enclosure-asset-tag'"
        )
      ]
    ~doc:
      "Set custom BIOS strings to this VM. VM will be given a default set of \
       BIOS strings, only some of which can be overridden by the supplied \
       values. Allowed keys are: 'bios-vendor', 'bios-version', \
       'system-manufacturer', 'system-product-name', 'system-version', \
       'system-serial-number', 'enclosure-asset-tag', \
       'baseboard-manufacturer', 'baseboard-product-name', \
       'baseboard-version', 'baseboard-serial-number', 'baseboard-asset-tag', \
       'baseboard-location-in-chassis', 'enclosure-asset-tag'"
    ~params:
      [
        (Ref _vm, "self", "The VM to modify")
      ; ( Map (String, String)
        , "value"
        , "The custom BIOS strings as a list of key-value pairs"
        )
      ]
    ~allowed_roles:_R_VM_ADMIN
    ~errs:[Api_errors.vm_bios_strings_already_set; Api_errors.invalid_value]
    ()

let copy_bios_strings =
  call ~name:"copy_bios_strings"
    ~lifecycle:
      [
        ( Published
        , rel_midnight_ride
        , "Copy the BIOS strings from the given host to this VM"
        )
      ]
    ~doc:"Copy the BIOS strings from the given host to this VM"
    ~params:
      [
        (Ref _vm, "vm", "The VM to modify")
      ; (Ref _host, "host", "The host to copy the BIOS strings from")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let set_protection_policy =
  call ~name:"set_protection_policy" ~in_oss_since:None ~lifecycle:vmpp_removed
    ~doc:"Set the value of the protection_policy field"
    ~params:[(Ref _vm, "self", "The VM"); (Ref _vmpp, "value", "The value")]
    ~flags:[`Session] ~allowed_roles:_R_POOL_OP ()

let set_snapshot_schedule =
  call ~name:"set_snapshot_schedule" ~in_oss_since:None
    ~lifecycle:
      [(Published, rel_falcon, "Set the value of the snapshot schedule field")]
    ~doc:"Set the value of the snapshot schedule field"
    ~params:[(Ref _vm, "self", "The VM"); (Ref _vmss, "value", "The value")]
    ~flags:[`Session] ~allowed_roles:_R_POOL_OP ()

let set_start_delay =
  call ~name:"set_start_delay"
    ~lifecycle:[(Published, rel_boston, "Set this VM's start delay in seconds")]
    ~doc:"Set this VM's start delay in seconds"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "value", "This VM's start delay in seconds")
      ]
    ~allowed_roles:_R_POOL_OP ()

let set_shutdown_delay =
  call ~name:"set_shutdown_delay"
    ~lifecycle:
      [(Published, rel_boston, "Set this VM's shutdown delay in seconds")]
    ~doc:"Set this VM's shutdown delay in seconds"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Int, "value", "This VM's shutdown delay in seconds")
      ]
    ~allowed_roles:_R_POOL_OP ()

let set_order =
  call ~name:"set_order"
    ~lifecycle:[(Published, rel_boston, "Set this VM's boot order")]
    ~doc:"Set this VM's boot order"
    ~params:
      [(Ref _vm, "self", "The VM"); (Int, "value", "This VM's boot order")]
    ~allowed_roles:_R_POOL_OP ()

let set_suspend_VDI =
  call ~name:"set_suspend_VDI"
    ~lifecycle:
      [
        ( Published
        , rel_boston
        , "Set this VM's suspend VDI, which must be indentical to its current \
           one"
        )
      ]
    ~doc:
      "Set this VM's suspend VDI, which must be indentical to its current one"
    ~params:
      [(Ref _vm, "self", "The VM"); (Ref _vdi, "value", "The suspend VDI uuid")]
    ~allowed_roles:_R_POOL_OP ()

let assert_can_be_recovered =
  call ~name:"assert_can_be_recovered"
    ~lifecycle:
      [
        ( Published
        , rel_boston
        , "Assert whether all SRs required to recover this VM are available."
        )
      ]
    ~doc:"Assert whether all SRs required to recover this VM are available."
    ~params:
      [
        (Ref _vm, "self", "The VM to recover")
      ; ( Ref _session
        , "session_to"
        , "The session to which the VM is to be recovered."
        )
      ]
    ~errs:[Api_errors.vm_is_part_of_an_appliance; Api_errors.vm_requires_sr]
    ~allowed_roles:_R_READ_ONLY ()

let get_SRs_required_for_recovery =
  call ~name:"get_SRs_required_for_recovery"
    ~lifecycle:
      [
        ( Published
        , rel_creedence
        , "List all the SR's that are required for the VM to be recovered"
        )
      ]
    ~doc:"List all the SR's that are required for the VM to be recovered"
    ~params:
      [
        (Ref _vm, "self", "The VM for which the SRs have to be recovered")
      ; ( Ref _session
        , "session_to"
        , "The session to which the SRs of the VM have to be recovered."
        )
      ]
    ~result:(Set (Ref _sr), "refs for SRs required to recover the VM")
    ~errs:[] ~allowed_roles:_R_READ_ONLY ()

let recover =
  call ~name:"recover"
    ~lifecycle:[(Published, rel_boston, "Recover the VM")]
    ~doc:"Recover the VM"
    ~params:
      [
        (Ref _vm, "self", "The VM to recover")
      ; ( Ref _session
        , "session_to"
        , "The session to which the VM is to be recovered."
        )
      ; ( Bool
        , "force"
        , "Whether the VM should replace newer versions of itself."
        )
      ]
    ~allowed_roles:_R_READ_ONLY ()

let set_appliance =
  call ~name:"set_appliance"
    ~lifecycle:[(Published, rel_boston, "Assign this VM to an appliance.")]
    ~doc:"Assign this VM to an appliance."
    ~params:
      [
        (Ref _vm, "self", "The VM to assign to an appliance.")
      ; ( Ref _vm_appliance
        , "value"
        , "The appliance to which this VM should be assigned."
        )
      ]
    ~allowed_roles:_R_POOL_OP ()

let set_groups =
  call ~name:"set_groups" ~lifecycle:[] ~doc:"Associate this VM with VM groups."
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Set (Ref _vm_group), "value", "The VM groups to set")
      ]
    ~errs:[Api_errors.operation_not_allowed]
    ~allowed_roles:_R_VM_ADMIN ()

let call_plugin =
  call ~name:"call_plugin"
    ~lifecycle:[(Published, rel_cream, "Call an API plugin on this vm")]
    ~doc:"Call an API plugin on this vm"
    ~params:
      [
        (Ref _vm, "vm", "The vm")
      ; (String, "plugin", "The name of the plugin")
      ; (String, "fn", "The name of the function within the plugin")
      ; (Map (String, String), "args", "Arguments for the function")
      ]
    ~result:(String, "Result from the plugin")
    ~allowed_roles:_R_VM_OP ()

let call_host_plugin =
  call ~name:"call_host_plugin"
    ~doc:"Call an API plugin on the host where this vm resides" ~lifecycle:[]
    ~params:
      [
        (Ref _vm, "vm", "The vm")
      ; (String, "plugin", "The name of the plugin")
      ; (String, "fn", "The name of the function within the plugin")
      ; (Map (String, String), "args", "Arguments for the function")
      ]
    ~result:(String, "Result from the plugin")
    ~allowed_roles:_R_VM_OP ()

let set_has_vendor_device =
  call ~name:"set_has_vendor_device"
    ~lifecycle:
      [
        ( Published
        , rel_dundee
        , "Controls whether, when the VM starts in HVM mode, its virtual \
           hardware will include the emulated PCI device for which drivers may \
           be available through Windows Update. Usually this should never be \
           changed on a VM on which Windows has been installed: changing it on \
           such a VM is likely to lead to a crash on next start."
        )
      ]
    ~doc:
      "Controls whether, when the VM starts in HVM mode, its virtual hardware \
       will include the emulated PCI device for which drivers may be available \
       through Windows Update. Usually this should never be changed on a VM on \
       which Windows has been installed: changing it on such a VM is likely to \
       lead to a crash on next start."
    ~params:
      [
        (Ref _vm, "self", "The VM on which to set this flag")
      ; (Bool, "value", "True to provide the vendor PCI device.")
      ]
    ~allowed_roles:_R_VM_ADMIN ~doc_tags:[Windows] ()

let import =
  call ~name:"import"
    ~lifecycle:[(Published, rel_dundee, "Import an XVA from a URI")]
    ~doc:"Import an XVA from a URI"
    ~params:
      [
        (String, "url", "The URL of the XVA file")
      ; (Ref _sr, "sr", "The destination SR for the disks")
      ; (Bool, "full_restore", "Perform a full restore")
      ; (Bool, "force", "Force the import")
      ]
    ~result:(Set (Ref _vm), "Imported VM reference")
    ~allowed_roles:_R_POOL_OP ()

let operations =
  Enum
    ( "vm_operations"
    , List.map operation_enum
        [
          snapshot
        ; clone
        ; copy
        ; create_template
        ; revert
        ; checkpoint
        ; snapshot_with_quiesce
        ; provision
        ; start
        ; start_on
        ; pause
        ; unpause
        ; cleanShutdown
        ; cleanReboot
        ; hardShutdown
        ; stateReset
        ; hardReboot
        ; suspend
        ; csvm
        ; resume
        ; resume_on
        ; pool_migrate
        ; migrate_send
        ; get_boot_record
        ; send_sysrq
        ; send_trigger
        ; query_services
        ; shutdown
        ; call_plugin
        ]
      @ [
          ("changing_memory_live", "Changing the memory settings")
        ; ("awaiting_memory_live", "Waiting for the memory settings to change")
        ; ("changing_dynamic_range", "Changing the memory dynamic range")
        ; ("changing_static_range", "Changing the memory static range")
        ; ("changing_memory_limits", "Changing the memory limits")
        ; ( "changing_shadow_memory"
          , "Changing the shadow memory for a halted VM."
          )
        ; ( "changing_shadow_memory_live"
          , "Changing the shadow memory for a running VM."
          )
        ; ("changing_VCPUs", "Changing VCPU settings for a halted VM.")
        ; ("changing_VCPUs_live", "Changing VCPU settings for a running VM.")
        ; ("changing_NVRAM", "Changing NVRAM for a halted VM.")
        ; ("assert_operation_valid", "")
        ; ("data_source_op", "Add, remove, query or list data sources")
        ; ("update_allowed_operations", "")
        ; ("make_into_template", "Turning this VM into a template")
        ; ("import", "importing a VM from a network stream")
        ; ("export", "exporting a VM to a network stream")
        ; ("metadata_export", "exporting VM metadata to a network stream")
        ; ("reverting", "Reverting the VM to a previous snapshotted state")
        ; ("destroy", "refers to the act of uninstalling the VM")
        ; ("create_vtpm", "Creating and adding a VTPM to this VM")
        ; ("sysprep", "Performing a Windows sysprep on this VM")
        ]
    )

let set_blocked_operations =
  call ~name:"set_blocked_operations"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Update list of operations which have been explicitly blocked and an \
           error code"
        )
      ]
      (* but updated 2024 *)
    ~doc:
      "Update list of operations which have been explicitly blocked and an \
       error code"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (Map (operations, String), "value", "Blocked operations")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let add_to_blocked_operations =
  call ~name:"add_to_blocked_operations"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Update list of operations which have been explicitly blocked and an \
           error code"
        )
      ]
      (* but updated 2024 *)
    ~doc:
      "Update list of operations which have been explicitly blocked and an \
       error code"
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (operations, "key", "Blocked operation")
      ; (String, "value", "Error code")
      ]
    ~allowed_roles:_R_VM_ADMIN ()

let remove_from_blocked_operations =
  call ~name:"remove_from_blocked_operations"
    ~lifecycle:
      [
        ( Published
        , rel_orlando
        , "Update list of operations which have been explicitly blocked and an \
           error code"
        )
      ]
      (* but updated 2024 *)
    ~doc:
      "Update list of operations which have been explicitly blocked and an \
       error code"
    ~params:
      [(Ref _vm, "self", "The VM"); (operations, "key", "Blocked operation")]
    ~allowed_roles:_R_VM_ADMIN ()

let assert_operation_valid =
  call ~in_oss_since:None
    ~lifecycle:
      [
        ( Published
        , rel_rio
        , "Check to see whether this operation is acceptable in the current \
           state of the system, raising an error if the operation is invalid \
           for some reason"
        )
      ]
    ~name:"assert_operation_valid"
    ~doc:
      "Check to see whether this operation is acceptable in the current state \
       of the system, raising an error if the operation is invalid for some \
       reason"
    ~params:
      [
        (Ref _vm, _self, "reference to the object")
      ; (operations, "op", "proposed operation")
      ]
    ~allowed_roles:_R_READ_ONLY ()

let update_allowed_operations =
  call ~in_oss_since:None
    ~lifecycle:
      [(Published, rel_rio, "Recomputes the list of acceptable operations")]
    ~name:"update_allowed_operations"
    ~doc:"Recomputes the list of acceptable operations"
    ~params:[(Ref _vm, _self, "reference to the object")]
    ~allowed_roles:_R_POOL_ADMIN ()

let domain_type =
  Enum
    ( "domain_type"
    , [
        ("hvm", "HVM; Fully Virtualised")
      ; ("pv", "PV: Paravirtualised")
      ; ("pv_in_pvh", "PV inside a PVH container")
      ; ("pvh", "PVH")
      ; ("unspecified", "Not specified or unknown domain type")
      ]
    )

let set_domain_type =
  call ~flags:[`Session] ~name:"set_domain_type"
    ~lifecycle:[(Published, rel_kolkata, "")]
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (domain_type, "value", "The new domain type")
      ]
    ~doc:
      "Set the VM.domain_type field of the given VM, which will take effect \
       when it is next started"
    ~allowed_roles:_R_VM_ADMIN ()

let set_HVM_boot_policy =
  call ~flags:[`Session] ~name:"set_HVM_boot_policy"
    ~lifecycle:
      [
        (Published, rel_rio, "")
      ; (Deprecated, rel_kolkata, "Replaced by VM.set_domain_type")
      ]
    ~params:
      [
        (Ref _vm, "self", "The VM"); (String, "value", "The new HVM boot policy")
      ]
    ~doc:
      "Set the VM.HVM_boot_policy field of the given VM, which will take \
       effect when it is next started"
    ~allowed_roles:_R_VM_ADMIN ()

let set_NVRAM_EFI_variables =
  call ~flags:[`Session] ~name:"set_NVRAM_EFI_variables"
    ~lifecycle:[(Published, rel_naples, "")]
    ~params:[(Ref _vm, "self", "The VM"); (String, "value", "The value")]
    ~hide_from_docs:true ~allowed_roles:_R_LOCAL_ROOT_ONLY ()

let restart_device_models =
  call ~name:"restart_device_models" ~lifecycle:[]
    ~params:[(Ref _vm, "self", "The VM")]
    ~doc:"Restart device models of the VM"
    ~errs:
      [
        Api_errors.vm_bad_power_state
      ; Api_errors.other_operation_in_progress
      ; Api_errors.vm_is_template
      ; Api_errors.operation_not_allowed
      ; Api_errors.vm_bad_power_state
      ]
    ~allowed_roles:(_R_VM_POWER_ADMIN ++ _R_CLIENT_CERT)
    ()

let sysprep =
  call ~name:"sysprep" ~lifecycle:[]
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (String, "unattend", "XML content passed to sysprep")
      ; (Float, "timeout", "timeout in seconds for expected reboot")
      ]
    ~doc:
      "Pass unattend.xml to Windows sysprep and wait for the VM to shut down \
       as part of a reboot."
    ~allowed_roles:_R_VM_ADMIN ()

let vm_uefi_mode =
  Enum
    ( "vm_uefi_mode"
    , [
        ( "setup"
        , "clears a VM's EFI variables related to Secure Boot and places it \
           into Setup Mode"
        )
      ; ( "user"
        , "resets a VM's EFI variables related to Secure Boot to the defaults, \
           placing it into User Mode"
        )
      ]
    )

let set_uefi_mode =
  call ~name:"set_uefi_mode" ~lifecycle:[]
    ~params:
      [
        (Ref _vm, "self", "The VM")
      ; (vm_uefi_mode, "mode", "The UEFI mode to set")
      ]
    ~result:(String, "Result from the varstore-sb-state call")
    ~doc:"Set the UEFI mode of a VM" ~allowed_roles:_R_POOL_ADMIN ()

let vm_secureboot_readiness =
  Enum
    ( "vm_secureboot_readiness"
    , [
        ("not_supported", "VM's firmware is not UEFI")
      ; ("disabled", "Secureboot is disabled on this VM")
      ; ( "first_boot"
        , "Secured boot is enabled on this VM and its NVRAM.EFI-variables are \
           empty"
        )
      ; ( "ready"
        , "Secured boot is enabled on this VM and PK, KEK, db and dbx are \
           defined in its EFI variables"
        )
      ; ( "ready_no_dbx"
        , "Secured boot is enabled on this VM and PK, KEK, db but not dbx are \
           defined in its EFI variables"
        )
      ; ( "setup_mode"
        , "Secured boot is enabled on this VM and PK is not defined in its EFI \
           variables"
        )
      ; ( "certs_incomplete"
        , "Secured boot is enabled on this VM and the certificates defined in \
           its EFI variables are incomplete"
        )
      ]
    )

let get_secureboot_readiness =
  call ~name:"get_secureboot_readiness" ~lifecycle:[]
    ~params:[(Ref _vm, "self", "The VM")]
    ~result:(vm_secureboot_readiness, "The secureboot readiness of the VM")
    ~doc:"Return the secureboot readiness of the VM"
    ~allowed_roles:_R_POOL_ADMIN ()

(** VM (or 'guest') configuration: *)
let t =
  create_obj ~in_db:true ~in_oss_since:oss_since_303 ~persist:PersistEverything
    ~gen_constructor_destructor:true ~name:_vm
    ~descr:"A virtual machine (or 'guest')." ~gen_events:true
    ~doccomments:
      [
        ( "destroy"
        , "Destroy the specified VM.  The VM is completely removed from the \
           system.  This function can only be called when the VM is in the \
           Halted State."
        )
      ; ( "create"
        , "NOT RECOMMENDED! VM.clone or VM.copy (or VM.import) is a better \
           choice in almost all situations. The standard way to obtain a new \
           VM is to call VM.clone on a template VM, then call VM.provision on \
           the new clone. Caution: if VM.create is used and then the new VM is \
           attached to a virtual disc that has an operating system already \
           installed, then there is no guarantee that the operating system \
           will boot and run. Any software that calls VM.create on a future \
           version of this API may fail or give unexpected results. For \
           example this could happen if an additional parameter were added to \
           VM.create. VM.create is intended only for use in the automatic \
           creation of the system VM templates. It creates a new VM instance, \
           and returns its handle."
        )
      ]
    ~lifecycle:
      [
        (Published, rel_rio, "")
      ; ( Changed
        , "1.257.0"
        , "possibility to create a VM in suspended mode with a suspend_VDI set"
        )
      ]
    ~messages_default_allowed_roles:_R_VM_ADMIN
    ~messages:
      [
        snapshot
      ; snapshot_with_quiesce
      ; clone
      ; copy
      ; revert
      ; checkpoint
      ; provision
      ; start
      ; start_on
      ; pause
      ; unpause
      ; cleanShutdown
      ; shutdown
      ; cleanReboot
      ; hardShutdown
      ; stateReset
      ; hardReboot
      ; suspend
      ; csvm
      ; resume
      ; set_is_default_template
      ; hardReboot_internal
      ; resume_on
      ; pool_migrate
      ; pool_migrate_complete
      ; set_vcpus_number_live
      ; add_to_VCPUs_params_live
      ; set_NVRAM
      ; add_to_NVRAM
      ; remove_from_NVRAM
      ; set_ha_restart_priority
      ; (* updates the allowed-operations of the VM *)
        set_ha_always_run
      ; (* updates the allowed-operations of the VM *)
        compute_memory_overhead
      ; set_memory_dynamic_max
      ; set_memory_dynamic_min
      ; set_memory_dynamic_range
      ; set_memory_static_max
      ; set_memory_static_min
      ; set_memory_static_range
      ; set_memory_limits
      ; set_memory
      ; set_memory_target_live
      ; wait_memory_target_live
      ; get_cooperative
      ; set_HVM_shadow_multiplier
      ; set_shadow_multiplier_live
      ; set_VCPUs_max
      ; set_VCPUs_at_startup
      ; send_sysrq
      ; send_trigger
      ; maximise_memory
      ; migrate_send
      ; assert_can_migrate
      ; assert_can_migrate_sender
      ; get_boot_record
      ; get_data_sources
      ; record_data_source
      ; query_data_source
      ; forget_data_source_archives
      ; assert_operation_valid
      ; update_allowed_operations
      ; get_allowed_VBD_devices
      ; get_allowed_VIF_devices
      ; get_possible_hosts
      ; assert_can_boot_here
      ; atomic_set_resident_on
      ; create_new_blob
      ; s3_suspend
      ; s3_resume
      ; assert_agile
      ; update_snapshot_metadata
      ; retrieve_wlb_recommendations
      ; set_bios_strings
      ; copy_bios_strings
      ; set_protection_policy
      ; set_snapshot_schedule
      ; set_start_delay
      ; set_shutdown_delay
      ; set_order
      ; set_suspend_VDI
      ; assert_can_be_recovered
      ; get_SRs_required_for_recovery
      ; recover
      ; import_convert
      ; set_appliance
      ; set_groups
      ; query_services
      ; call_plugin
      ; call_host_plugin
      ; set_has_vendor_device
      ; import
      ; set_actions_after_crash
      ; set_domain_type
      ; set_HVM_boot_policy
      ; set_NVRAM_EFI_variables
      ; restart_device_models
      ; set_uefi_mode
      ; get_secureboot_readiness
      ; set_blocked_operations
      ; add_to_blocked_operations
      ; remove_from_blocked_operations
      ; sysprep
      ]
    ~contents:
      ([
         uid _vm
           ~lifecycle:
             [(Published, rel_rio, "Unique identifier/object reference")]
       ]
      @ allowed_and_current_operations operations
      @ [
          namespace ~name:"name"
            ~contents:
              (names oss_since_303 RW ~lifecycle:[(Published, rel_rio, "")])
            ()
        ; field ~writer_roles:_R_VM_OP ~qualifier:StaticRO
            ~default_value:(Some (VEnum "Halted"))
            ~lifecycle:
              [
                (Published, rel_rio, "")
              ; ( Changed
                , "1.257.0"
                , "Made StaticRO to allow Suspended VM creation"
                )
              ]
            ~ty:power_state "power_state" "Current power state of the machine"
        ; field ~ty:Int "user_version"
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "Creators of VMs and templates may store version information \
                   here."
                )
              ]
            "Creators of VMs and templates may store version information here."
        ; field ~effect:true ~ty:Bool "is_a_template"
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "true if this is a template. Template VMs can never be \
                   started, they are used only for cloning other VMs"
                )
              ]
            "true if this is a template. Template VMs can never be started, \
             they are used only for cloning other VMs"
        ; field ~ty:Bool ~default_value:(Some (VBool false))
            ~qualifier:DynamicRO ~writer_roles:_R_POOL_ADMIN
            ~lifecycle:[(Published, rel_falcon, "Identifies default templates")]
            "is_default_template"
            "true if this is a default template. Default template VMs can \
             never be started or migrated, they are used only for cloning \
             other VMs"
        ; field ~qualifier:StaticRO ~default_value:(Some (VRef null_ref))
            ~lifecycle:
              [
                (Published, rel_rio, "")
              ; ( Changed
                , "1.257.0"
                , "Become static to allow Suspended VM creation"
                )
              ]
            ~ty:(Ref _vdi) "suspend_VDI"
            "The VDI that a suspend image is stored on. (Only has meaning if \
             VM is currently suspended)"
        ; field
            ~lifecycle:
              [(Published, rel_rio, "the host the VM is currently resident on")]
            ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO ~ty:(Ref _host)
            "resident_on" "the host the VM is currently resident on"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~in_oss_since:None
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "the host on which the VM is due to be \
                   started/resumed/migrated. This acts as a memory reservation \
                   indicator"
                )
              ]
            ~qualifier:DynamicRO ~default_value:(Some (VRef null_ref))
            ~ty:(Ref _host) "scheduled_to_be_resident_on"
            "the host on which the VM is due to be started/resumed/migrated. \
             This acts as a memory reservation indicator"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~in_oss_since:None
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "A host which the VM has some affinity for (or NULL). This \
                   is used as a hint to the start call when it decides where \
                   to run the VM. Resource constraints may cause the VM to be \
                   started elsewhere."
                )
              ]
            ~ty:(Ref _host) "affinity"
            "A host which the VM has some affinity for (or NULL). This is used \
             as a hint to the start call when it decides where to run the VM. \
             Resource constraints may cause the VM to be started elsewhere."
        ; namespace ~name:"memory" ~contents:guest_memory ()
        ; namespace ~name:"VCPUs" ~contents:vcpus ()
        ; namespace ~name:"actions" ~contents:actions ()
        ; field
            ~lifecycle:[(Published, rel_rio, "virtual console devices")]
            ~writer_roles:_R_POOL_ADMIN ~qualifier:DynamicRO
            ~ty:(Set (Ref _console)) "consoles" "virtual console devices"
        ; field
            ~lifecycle:[(Published, rel_rio, "virtual network interfaces")]
            ~qualifier:DynamicRO ~ty:(Set (Ref _vif)) ~doc_tags:[Networking]
            "VIFs" "virtual network interfaces"
        ; field
            ~lifecycle:[(Published, rel_rio, "virtual block devices")]
            ~qualifier:DynamicRO ~ty:(Set (Ref _vbd)) "VBDs"
            "virtual block devices"
        ; field
            ~lifecycle:[(Published, rel_rio, "virtual usb devices")]
            ~qualifier:DynamicRO ~ty:(Set (Ref _vusb)) "VUSBs"
            "virtual usb devices"
        ; field
            ~lifecycle:
              [(Published, rel_rio, "crash dumps associated with this VM")]
            ~writer_roles:_R_POOL_ADMIN ~qualifier:DynamicRO
            ~ty:(Set (Ref _crashdump)) "crash_dumps"
            "crash dumps associated with this VM"
        ; field
            ~lifecycle:[(Published, rel_rio, "virtual TPMs")]
            ~qualifier:DynamicRO ~ty:(Set (Ref _vtpm)) "VTPMs" "virtual TPMs"
        ; namespace ~name:"PV" ~contents:pv ()
        ; namespace ~name:"HVM" ~contents:hvm ()
        ; field
            ~ty:(Map (String, String))
            ~lifecycle:[(Published, rel_rio, "platform-specific configuration")]
            "platform" "platform-specific configuration"
        ; field
            ~lifecycle:
              [
                (Published, rel_rio, "PCI bus path for pass-through devices")
              ; (Deprecated, rel_boston, "Field was never used")
              ]
            "PCI_bus" "PCI bus path for pass-through devices"
        ; field
            ~lifecycle:[(Published, rel_rio, "additional configuration")]
            ~ty:(Map (String, String))
            "other_config" "additional configuration"
            ~map_keys_roles:
              [
                ("pci", _R_POOL_ADMIN)
              ; ("folder", _R_VM_OP)
              ; ("XenCenter.CustomFields.*", _R_VM_OP)
              ]
        ; field ~qualifier:DynamicRO ~ty:Int "domid"
            ~lifecycle:
              [(Published, rel_rio, "domain ID (if available, -1 otherwise)")]
            "domain ID (if available, -1 otherwise)"
        ; field ~qualifier:DynamicRO ~in_oss_since:None
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "Domain architecture (if available, null string otherwise)"
                )
              ]
            ~ty:String "domarch"
            "Domain architecture (if available, null string otherwise)"
        ; field ~in_oss_since:None
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "describes the CPU flags on which the VM was last booted"
                )
              ]
            ~qualifier:StaticRO
            ~ty:(Map (String, String))
            ~default_value:(Some (VMap [])) "last_boot_CPU_flags"
            "describes the CPU flags on which the VM was last booted"
        ; field
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "true if this is a control domain (domain 0 or a driver \
                   domain)"
                )
              ]
            ~qualifier:DynamicRO ~ty:Bool "is_control_domain"
            "true if this is a control domain (domain 0 or a driver domain)"
        ; field
            ~lifecycle:[(Published, rel_rio, "metrics associated with this VM")]
            ~qualifier:DynamicRO ~ty:(Ref _vm_metrics) "metrics"
            "metrics associated with this VM"
        ; field
            ~lifecycle:
              [
                (Published, rel_rio, "metrics associated with the running guest")
              ]
            ~qualifier:DynamicRO ~ty:(Ref _vm_guest_metrics) "guest_metrics"
            "metrics associated with the running guest"
        ; (* This was an internal field in Rio, Miami beta1, Miami beta2 but is now exposed so that
             	   it will be included automatically in Miami GA exports and can be restored, important if
             	   the VM is in a suspended state *)
          field ~in_oss_since:None ~internal_only:false
            ~lifecycle:
              [
                ( Published
                , rel_miami
                , "Marshalled value containing VM record at time of last boot, \
                   updated dynamically to reflect the runtime state of the \
                   domain"
                )
              ; ( Changed
                , "1.257.0"
                , "Become static to allow Suspended VM creation"
                )
              ]
            ~qualifier:StaticRO ~ty:String "last_booted_record"
            "marshalled value containing VM record at time of last boot"
            ~default_value:(Some (VString ""))
        ; field ~in_oss_since:None
            ~lifecycle:
              [
                ( Published
                , rel_rio
                , "An XML specification of recommended values and ranges for \
                   properties of this VM"
                )
              ]
            ~ty:String "recommendations"
            "An XML specification of recommended values and ranges for \
             properties of this VM"
        ; field ~effect:true ~in_oss_since:None
            ~ty:(Map (String, String))
            ~lifecycle:
              [
                ( Published
                , rel_miami
                , "data to be inserted into the xenstore tree \
                   (/local/domain/<domid>/vm-data) after the VM is created."
                )
              ]
            ~qualifier:RW "xenstore_data"
            "data to be inserted into the xenstore tree \
             (/local/domain/<domid>/vm-data) after the VM is created."
            ~default_value:(Some (VMap []))
        ; field ~writer_roles:_R_POOL_OP ~in_oss_since:None ~ty:Bool
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "if true then the system will attempt to keep the VM running \
                   as much as possible."
                )
              ; (Deprecated, rel_boston, "")
              ]
            ~qualifier:StaticRO "ha_always_run"
            "if true then the system will attempt to keep the VM running as \
             much as possible."
            ~default_value:(Some (VBool false))
        ; field ~writer_roles:_R_POOL_OP ~in_oss_since:None ~ty:String
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "has possible values: \"best-effort\" meaning \"try to \
                   restart this VM if possible but don't consider the Pool to \
                   be overcommitted if this is not possible\"; \"restart\" \
                   meaning \"this VM should be restarted\"; \"\" meaning \"do \
                   not try to restart this VM\""
                )
              ]
            ~qualifier:StaticRO "ha_restart_priority"
            "has possible values: \"best-effort\" meaning \"try to restart \
             this VM if possible but don't consider the Pool to be \
             overcommitted if this is not possible\"; \"restart\" meaning \
             \"this VM should be restarted\"; \"\" meaning \"do not try to \
             restart this VM\""
            ~default_value:(Some (VString ""))
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "true if this is a snapshot. Snapshotted VMs can never be \
                   started, they are used only for cloning other VMs"
                )
              ]
            ~default_value:(Some (VBool false)) ~ty:Bool "is_a_snapshot"
            "true if this is a snapshot. Snapshotted VMs can never be started, \
             they are used only for cloning other VMs"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "Ref pointing to the VM this snapshot is of."
                )
              ]
            ~default_value:(Some (VRef "")) ~ty:(Ref _vm) "snapshot_of"
            "Ref pointing to the VM this snapshot is of."
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "List pointing to all the VM snapshots."
                )
              ]
            ~ty:(Set (Ref _vm)) "snapshots"
            "List pointing to all the VM snapshots."
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "Date/time when this snapshot was created."
                )
              ]
            ~default_value:(Some (VDateTime Date.epoch)) ~ty:DateTime
            "snapshot_time" "Date/time when this snapshot was created."
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [(Published, rel_orlando, "Transportable ID of the snapshot VM")]
            ~default_value:(Some (VString "")) ~ty:String
            "transportable_snapshot_id" "Transportable ID of the snapshot VM"
        ; field ~qualifier:DynamicRO
            ~lifecycle:
              [(Published, rel_orlando, "Binary blobs associated with this VM")]
            ~ty:(Map (String, Ref _blob))
            ~default_value:(Some (VMap [])) "blobs"
            "Binary blobs associated with this VM"
        ; field ~writer_roles:_R_VM_OP
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "user-specified tags for categorization purposes"
                )
              ]
            ~default_value:(Some (VSet [])) ~ty:(Set String) "tags"
            "user-specified tags for categorization purposes"
        ; field
            ~lifecycle:
              [
                ( Published
                , rel_orlando
                , "List of operations which have been explicitly blocked and \
                   an error code"
                )
              ]
            ~default_value:(Some (VMap [])) ~qualifier:StaticRO
            ~ty:(Map (operations, String))
            "blocked_operations"
            "List of operations which have been explicitly blocked and an \
             error code"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_midnight_ride
                , "Human-readable information concerning this snapshot"
                )
              ]
            ~default_value:(Some (VMap []))
            ~ty:(Map (String, String))
            "snapshot_info"
            "Human-readable information concerning this snapshot"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_midnight_ride
                , "Encoded information about the VM's metadata this is a \
                   snapshot of"
                )
              ]
            ~default_value:(Some (VString "")) ~ty:String "snapshot_metadata"
            "Encoded information about the VM's metadata this is a snapshot of"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_midnight_ride
                , "Ref pointing to the parent of this VM"
                )
              ]
            ~default_value:(Some (VRef "")) ~ty:(Ref _vm) "parent"
            "Ref pointing to the parent of this VM"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , rel_midnight_ride
                , "List pointing to all the children of this VM"
                )
              ]
            ~ty:(Set (Ref _vm)) "children"
            "List pointing to all the children of this VM"
        ; field ~qualifier:DynamicRO
            ~lifecycle:[(Published, rel_midnight_ride, "BIOS strings")]
            ~default_value:(Some (VMap []))
            ~ty:(Map (String, String))
            "bios_strings" "BIOS strings"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
            ~lifecycle:vmpp_deprecated ~default_value:(Some (VRef null_ref))
            ~ty:(Ref _vmpp) "protection_policy"
            "Ref pointing to a protection policy for this VM"
        ; field ~writer_roles:_R_POOL_OP ~qualifier:StaticRO
            ~lifecycle:vmpp_removed ~default_value:(Some (VBool false)) ~ty:Bool
            "is_snapshot_from_vmpp"
            "true if this snapshot was created by the protection policy"
        ; field ~writer_roles:_R_VM_POWER_ADMIN ~qualifier:StaticRO
            ~lifecycle:
              [
                ( Published
                , rel_falcon
                , "Ref pointing to a snapshot schedule for this VM"
                )
              ]
            ~default_value:(Some (VRef null_ref)) ~ty:(Ref _vmss)
            "snapshot_schedule"
            "Ref pointing to a snapshot schedule for this VM"
        ; field ~writer_roles:_R_POOL_OP ~qualifier:StaticRO
            ~lifecycle:
              [
                ( Published
                , rel_falcon
                , "true if this snapshot was created by the snapshot schedule"
                )
              ]
            ~default_value:(Some (VBool false)) ~ty:Bool "is_vmss_snapshot"
            "true if this snapshot was created by the snapshot schedule"
        ; field ~writer_roles:_R_POOL_OP ~qualifier:StaticRO
            ~lifecycle:
              [(Published, rel_rio, "the appliance to which this VM belongs")]
            ~ty:(Ref _vm_appliance) ~default_value:(Some (VRef null_ref))
            "appliance" "the appliance to which this VM belongs"
        ; field ~writer_roles:_R_POOL_OP ~qualifier:StaticRO
            ~lifecycle:
              [
                ( Published
                , rel_boston
                , "The delay to wait before proceeding to the next order in \
                   the startup sequence (seconds)"
                )
              ]
            ~default_value:(Some (VInt 0L)) ~ty:Int "start_delay"
            "The delay to wait before proceeding to the next order in the \
             startup sequence (seconds)"
        ; field ~writer_roles:_R_POOL_OP ~qualifier:StaticRO
            ~lifecycle:
              [
                ( Published
                , rel_boston
                , "The delay to wait before proceeding to the next order in \
                   the shutdown sequence (seconds)"
                )
              ]
            ~default_value:(Some (VInt 0L)) ~ty:Int "shutdown_delay"
            "The delay to wait before proceeding to the next order in the \
             shutdown sequence (seconds)"
        ; field ~writer_roles:_R_POOL_OP ~qualifier:StaticRO
            ~lifecycle:
              [
                ( Published
                , rel_boston
                , "The point in the startup or shutdown sequence at which this \
                   VM will be started"
                )
              ]
            ~default_value:(Some (VInt 0L)) ~ty:Int "order"
            "The point in the startup or shutdown sequence at which this VM \
             will be started"
        ; field ~qualifier:DynamicRO
            ~lifecycle:[(Published, rel_boston, "")]
            ~ty:(Set (Ref _vgpu)) "VGPUs" "Virtual GPUs"
        ; field ~qualifier:DynamicRO
            ~lifecycle:[(Published, rel_boston, "")]
            ~ty:(Set (Ref _pci)) "attached_PCIs"
            "Currently passed-through PCI devices"
        ; field ~writer_roles:_R_VM_ADMIN ~qualifier:RW
            ~lifecycle:
              [
                ( Published
                , rel_boston
                , "The SR on which a suspend image is stored"
                )
              ]
            ~default_value:(Some (VRef null_ref)) ~ty:(Ref _sr) "suspend_SR"
            "The SR on which a suspend image is stored"
        ; field ~qualifier:StaticRO
            ~lifecycle:
              [
                ( Published
                , rel_boston
                , "The number of times this VM has been recovered"
                )
              ]
            ~default_value:(Some (VInt 0L)) ~ty:Int "version"
            "The number of times this VM has been recovered"
        ; field ~qualifier:StaticRO
            ~lifecycle:[(Published, rel_clearwater, "Generation ID of the VM")]
            ~default_value:(Some (VString "0:0")) ~ty:String "generation_id"
            "Generation ID of the VM"
        ; field ~writer_roles:_R_VM_ADMIN ~qualifier:RW
            ~lifecycle:
              [
                ( Published
                , rel_cream
                , "The host virtual hardware platform version the VM can run on"
                )
              ]
            ~default_value:(Some (VInt 0L)) ~ty:Int "hardware_platform_version"
            "The host virtual hardware platform version the VM can run on"
        ; field ~qualifier:StaticRO
            ~lifecycle:
              [
                (Published, rel_dundee, "")
              ; ( Changed
                , "24.14.0"
                , "New default and not consulting Pool.policy_no_vendor_device"
                )
              ]
            ~doc_tags:[Windows] ~default_value:(Some (VBool true)) ~ty:Bool
            "has_vendor_device"
            "When an HVM guest starts, this controls the presence of the \
             emulated C000 PCI device which triggers Windows Update to fetch \
             or update PV drivers."
        ; field ~qualifier:DynamicRO ~ty:Bool
            ~lifecycle:[(Published, rel_ely, "")]
            ~default_value:(Some (VBool false)) "requires_reboot"
            "Indicates whether a VM requires a reboot in order to update its \
             configuration, e.g. its memory allocation."
        ; field ~qualifier:StaticRO ~ty:String
            ~lifecycle:
              [
                ( Published
                , rel_ely
                , "Textual reference to the template used to create a VM. This \
                   can be used by clients in need of an immutable reference to \
                   the template since the latter's uuid and name_label may \
                   change, for example, after a package installation or \
                   upgrade."
                )
              ]
            ~default_value:(Some (VString "")) "reference_label"
            "Textual reference to the template used to create a VM. This can \
             be used by clients in need of an immutable reference to the \
             template since the latter's uuid and name_label may change, for \
             example, after a package installation or upgrade."
        ; field ~qualifier:StaticRO ~ty:domain_type
            ~lifecycle:
              [
                ( Prototyped
                , rel_jura
                , "Internal-only field; not yet in the public API"
                )
              ; (Published, rel_kolkata, "The field is now valid")
              ]
            ~default_value:(Some (VEnum "unspecified")) "domain_type"
            "The type of domain that will be created when the VM is started"
        ; field
            ~lifecycle:[(Published, rel_naples, "")]
            ~qualifier:StaticRO
            ~ty:(Map (String, String))
            "NVRAM" ~default_value:(Some (VMap []))
            "initial value for guest NVRAM (containing UEFI variables, etc). \
             Cannot be changed while the VM is running"
        ; field ~qualifier:DynamicRO
            ~lifecycle:
              [
                ( Published
                , "1.303.0"
                , "The set of pending mandatory guidances after applying \
                   updates, which must be applied, as otherwise there may be \
                   e.g. VM failures"
                )
              ]
            ~ty:(Set update_guidances) "pending_guidances"
            ~default_value:(Some (VSet []))
            "The set of pending mandatory guidances after applying updates, \
             which must be applied, as otherwise there may be e.g. VM failures"
        ; field ~qualifier:DynamicRO ~internal_only:true
            ~lifecycle:[(Prototyped, "23.18.0", ""); (Removed, "23.24.0", "")]
            ~ty:(Set update_guidances) "recommended_guidances"
            ~default_value:(Some (VSet []))
            "The set of recommended guidances after applying updates"
        ; field ~qualifier:DynamicRO ~lifecycle:[] ~ty:(Set update_guidances)
            "pending_guidances_recommended" ~default_value:(Some (VSet []))
            "The set of pending recommended guidances after applying updates, \
             which most users should follow to make the updates effective, but \
             if not followed, will not cause a failure"
        ; field ~qualifier:DynamicRO ~lifecycle:[] ~ty:(Set update_guidances)
            "pending_guidances_full" ~default_value:(Some (VSet []))
            "The set of pending full guidances after applying updates, which a \
             user should follow to make some updates, e.g. specific hardware \
             drivers or CPU features, fully effective, but the 'average user' \
             doesn't need to"
        ; field ~qualifier:DynamicRO ~lifecycle:[] ~ty:(Set (Ref _vm_group))
            "groups" "VM groups associated with the VM"
        ]
      )
    ()
