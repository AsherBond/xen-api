(* Copyright (C) Citrix Systems Inc.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License as published
   by the Free Software Foundation; version 2.1 only. with the special
   exception on linking described in file LICENSE.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.
*)

module D = Debug.Make (struct let name = "service" end)

open! D
module Unixext = Xapi_stdext_unix.Unixext
module Xenops_task = Xenops_task.Xenops_task
module Chroot = Xenops_sandbox.Chroot
module Path = Chroot.Path
module Xs = Xenstore.Xs
module Socket = Xenops_utils.Socket

let defer f g = Xapi_stdext_pervasives.Pervasiveext.finally g f

exception Service_failed of (string * string)

type t = {
    name: string
  ; domid: Xenctrl.domid
  ; exec_path: string
  ; chroot: Chroot.t
  ; timeout_seconds: float
  ; args: string list
  ; execute:
      path:string -> args:string list -> domid:Xenctrl.domid -> unit -> string
}

let alive service =
  let is_active = Fe_systemctl.is_active ~service in
  ( if not is_active then
      let status = Fe_systemctl.show ~service in
      error
        "%s: unexpected termination \
         (Result=%s,ExecMainPID=%d,ExecMainStatus=%d,ActiveState=%s)"
        service status.result status.exec_main_pid status.exec_main_status
        status.active_state
  ) ;
  is_active

type watch_trigger = Created | Cancelled | Waiting

let fold_events ~init f events =
  events
  |> List.to_seq
  |> Seq.flat_map (fun (_, events, _, fnameopt) ->
         List.to_seq events |> Seq.map (fun event -> (event, fnameopt))
     )
  |> Seq.fold_left f init

exception ECancelled of Xenops_task.task_handle

let raise_e = function
  | ECancelled t ->
      Xenops_task.raise_cancelled t
  | e ->
      raise e

let with_inotify f =
  let fd = Inotify.create () in
  defer (fun () -> Unix.close fd) (fun () -> f fd)

let with_watch notifd dir f =
  let open Inotify in
  let flags = [S_Create; S_Delete; S_Delete_self; S_Onlydir] in
  let watch = Inotify.add_watch notifd dir flags in
  defer (fun () -> Inotify.rm_watch notifd watch) (fun () -> f watch)

let with_monitor watch_fd f =
  let fd = Polly.create () in
  Polly.add fd watch_fd Polly.Events.inp ;
  defer (fun () -> Polly.del fd watch_fd ; Polly.close fd) (fun () -> f fd)

let start_and_wait_for_readyness ~task ~service =
  let sandbox_path p =
    Chroot.absolute_path_outside service.chroot (Path.of_string ~relative:p)
  in

  let pid_name = Printf.sprintf "%s-%d.pid" service.name service.domid in
  let cancel_name =
    Printf.sprintf "%s-%s.cancel" service.name (Xenops_task.get_dbg task)
  in

  let cancel_path = sandbox_path cancel_name in

  let cancel () =
    (* create an empty file to trigger the watch and delete it
       immediately *)
    Unixext.touch_file cancel_path ;
    Unixext.unlink_safe cancel_path
  in
  (* create watches for pidfile and task cancellation *)
  with_inotify @@ fun notifd ->
  with_watch notifd service.chroot.root @@ fun _ ->
  with_monitor notifd @@ fun pollfd ->
  let wait ~for_s ~service_name =
    let start_time = Mtime_clock.elapsed () in
    let poll_period_ms = 1000 in
    let collect_watches acc (event, file) =
      match (acc, event, file) with
      (* treat deleted directory or pidfile as cancelling *)
      | Cancelled, _, _ | _, (Inotify.Ignored | Inotify.Delete_self), _ ->
          Cancelled
      | _, Inotify.Delete, Some name when name = pid_name ->
          Cancelled
      | _, Inotify.Create, Some name when name = cancel_name ->
          Cancelled
      | _, Inotify.Create, Some name when name = pid_name ->
          Created
      | _, _, _ ->
          acc
    in

    let cancellable_watch () =
      let event = ref Waiting in
      let rec poll_loop () =
        try
          ignore
          @@ Polly.wait pollfd 1 poll_period_ms (fun _ fd events ->
                 if Polly.Events.(test events inp) then
                   event :=
                     fold_events ~init:!event collect_watches (Inotify.read fd)
             ) ;

          let current_time = Mtime_clock.elapsed () in
          let elapsed_time =
            Mtime.Span.(to_s (abs_diff start_time current_time))
          in

          match !event with
          | Waiting when elapsed_time < for_s ->
              poll_loop ()
          | Created ->
              Ok ()
          | Cancelled ->
              Error (ECancelled task)
          | Waiting ->
              let err_msg =
                if alive service_name then
                  "Timeout reached while starting service"
                else
                  "Service exited unexpectedly"
              in
              Error (Service_failed (service_name, err_msg))
        with e ->
          let err_msg =
            Printf.sprintf
              "Exception while waiting for service %s to be ready: %s"
              service_name (Printexc.to_string e)
          in
          Error (Service_failed (service_name, err_msg))
      in

      Xenops_task.with_cancel task cancel poll_loop
    in
    cancellable_watch ()
  in

  (* start systemd service *)
  let syslog_key =
    service.execute ~path:service.exec_path ~args:service.args
      ~domid:service.domid ()
  in

  Xenops_task.check_cancelling task ;

  (* wait for pidfile to appear *)
  Result.iter_error raise_e
    (wait ~for_s:service.timeout_seconds ~service_name:syslog_key) ;

  debug "Service %s initialized" syslog_key

(* Waits for a daemon to signal startup by writing to a xenstore path
   (optionally with a given value) If this doesn't happen in the timeout then
   an exception is raised *)
let wait_path ~pidalive ~task ~name ~domid ~xs ~ready_path ~timeout ~cancel _ =
  let syslog_key = Printf.sprintf "%s-%d" name domid in
  let watch = Watch.value_to_appear ready_path |> Watch.map (fun _ -> ()) in
  Xenops_task.check_cancelling task ;
  ( try
      let (_ : bool) =
        Cancel_utils.cancellable_watch cancel [watch] [] task ~xs ~timeout ()
      in
      ()
    with Watch.Timeout _ ->
      if pidalive name then
        raise (Service_failed (name, "Timeout reached while starting daemon")) ;
      raise (Service_failed (name, "Daemon exited unexpectedly"))
  ) ;
  debug "Daemon initialised: %s" syslog_key

module type DAEMONPIDPATH = sig
  val name : string

  val use_pidfile : bool

  val pid_path : int -> string
end

module DaemonMgmt (D : DAEMONPIDPATH) = struct
  module SignalMask = struct
    module H = Hashtbl

    type t = (int, bool) H.t

    let create () = H.create 16

    let set tbl key = H.replace tbl key true

    let unset tbl key = H.remove tbl key

    let has tbl key = H.mem tbl key
  end

  let signal_mask = SignalMask.create ()

  let name = D.name

  let pid_path = D.pid_path

  let pid_path_signal domid = pid_path domid ^ "-signal"

  let pidfile_path domid =
    if D.use_pidfile then
      Some
        (Printf.sprintf "%s/%s-%d.pid" Device_common.var_run_xen_path D.name
           domid
        )
    else
      None

  let pid ~xs domid =
    try
      match pidfile_path domid with
      | Some path when Sys.file_exists path ->
          let pid =
            path |> Unixext.string_of_file |> String.trim |> int_of_string
          in
          Unixext.with_file path [Unix.O_RDONLY] 0 (fun fd ->
              try
                Unix.lockf fd Unix.F_TRLOCK 0 ;
                (* we succeeded taking the lock: original process is dead.
                 * some other process might've reused its pid *)
                None
              with Unix.Unix_error (Unix.EAGAIN, _, _) ->
                (* cannot obtain lock: process is alive *)
                Some pid
          )
      | _ ->
          (* backward compatibility during update installation: only has
             xenstore pid *)
          let pid = xs.Xs.read (pid_path domid) in
          Some (int_of_string pid)
    with _ -> None

  let is_running ~xs domid =
    match pid ~xs domid with
    | None ->
        false
    | Some p -> (
      try Unix.kill p 0 ; (* This checks the existence of pid p *)
                          true
      with _ -> false
    )

  let stop ~xs domid =
    match pid ~xs domid with
    | None ->
        ()
    | Some pid -> (
        let best_effort = Xenops_utils.best_effort in
        let really_kill = Xenops_utils.really_kill in
        debug "%s: stopping %s with SIGTERM (domid = %d pid = %d)" D.name D.name
          domid pid ;
        best_effort (Printf.sprintf "killing %s" D.name) (fun () ->
            really_kill pid
        ) ;
        let key = pid_path domid in
        best_effort (Printf.sprintf "removing XS key %s" key) (fun () ->
            xs.Xs.rm key
        ) ;
        match pidfile_path domid with
        | None ->
            ()
        | Some path ->
            best_effort (Printf.sprintf "removing %s" path) (fun () ->
                Unix.unlink path
            )
      )

  let syslog_key ~domid = Printf.sprintf "%s-%d" D.name domid

  let start ~fds ~syslog_key path args =
    let syslog_stdout = Forkhelpers.Syslog_WithKey syslog_key in
    let redirect_stderr_to_stdout = true in
    let pid =
      Forkhelpers.safe_close_and_exec None None None fds ~syslog_stdout
        ~redirect_stderr_to_stdout path args
    in
    debug
      "%s: should be running in the background (stdout -> syslog); (fd,pid) = \
       %s"
      D.name
      (Forkhelpers.string_of_pidty pid) ;
    pid

  (* Forks a daemon and then returns the pid. *)
  let start_daemon ~path ~args ~domid ?(fds = []) () =
    let syslog_key = syslog_key ~domid in
    debug "Starting daemon: %s with args [%s]" path (String.concat "; " args) ;
    let pid = start ~fds ~syslog_key path args in
    debug "Daemon started: %s" syslog_key ;
    pid
end

module Qemu = DaemonMgmt (struct
  let name = "qemu-dm"

  let use_pidfile = true

  let pid_path domid = Printf.sprintf "/local/domain/%d/qemu-pid" domid
end)

module Vgpu = struct
  module D = DaemonMgmt (struct
    let name = "vgpu"

    let use_pidfile = false

    let pid_path domid = Printf.sprintf "/local/domain/%d/vgpu-pid" domid
  end)

  let start_daemon = D.start_daemon

  let pid = D.pid

  let is_running = D.is_running

  let stop = D.stop

  let wait_path = wait_path
end

module SystemdDaemonMgmt (D : DAEMONPIDPATH) = struct
  (* backward compat: for daemons running during an update *)
  module Compat = DaemonMgmt (D)

  let pidfile_path = Compat.pidfile_path

  let pid_path = Compat.pid_path

  let of_domid domid =
    let key = Compat.syslog_key ~domid in
    if Fe_systemctl.exists ~service:key then
      Some key
    else
      None

  let is_running ~xs domid =
    match of_domid domid with
    | None ->
        Compat.is_running ~xs domid
    | Some key ->
        Fe_systemctl.is_active ~service:key

  let alive service _ =
    if Fe_systemctl.is_active ~service then
      true
    else
      let status = Fe_systemctl.show ~service in
      let open Fe_systemctl in
      error
        "%s: unexpected termination \
         (Result=%s,ExecMainPID=%d,ExecMainStatus=%d,ActiveState=%s)"
        service status.result status.exec_main_pid status.exec_main_status
        status.active_state ;
      false

  let stop ~xs domid =
    match of_domid domid with
    | None ->
        Compat.stop ~xs domid
    | Some service ->
        (* xenstore cleanup is done by systemd unit file *)
        let (_ : Fe_systemctl.status) = Fe_systemctl.stop ~service in
        ()

  let start_daemon ~path ~args ~domid () =
    debug "Starting daemon: %s with args [%s]" path (String.concat "; " args) ;
    let service = Compat.syslog_key ~domid in
    let pidpath = D.pid_path domid in
    let properties =
      ("ExecStopPost", "-/usr/bin/xenstore-rm " ^ pidpath)
      ::
      ( match Compat.pidfile_path domid with
      | None ->
          []
      | Some path ->
          [("ExecStopPost", "-/bin/rm -f " ^ path)]
      )
    in
    Fe_systemctl.start_transient ~properties ~service path args ;
    debug "Daemon started: %s" service ;
    service
end

module Varstored = struct
  module D = SystemdDaemonMgmt (struct
    let name = "varstored"

    let use_pidfile = true

    let pid_path domid = Printf.sprintf "/local/domain/%d/varstored-pid" domid
  end)

  let efivars_resume_path =
    Xenops_sandbox.Chroot.Path.of_string ~relative:"efi-vars-resume.dat"

  let efivars_save_path =
    Xenops_sandbox.Chroot.Path.of_string ~relative:"efi-vars-save.dat"

  let start ~xs ~nvram ?(restore = false) task domid =
    let open Xenops_types in
    debug "Preparing to start varstored for UEFI boot (domid=%d)" domid ;
    let path = !Xc_resources.varstored in
    let name = "varstored" in
    let vm_uuid = Xenops_helpers.uuid_of_domid ~xs domid |> Uuid.to_string in
    let reset_on_boot =
      nvram.Nvram_uefi_variables.on_boot = Nvram_uefi_variables.Reset
    in
    let backend = nvram.Nvram_uefi_variables.backend in
    let open Fe_argv in
    let argf fmt = Printf.ksprintf (fun s -> ["--arg"; s]) fmt in
    let on cond value = if cond then value else return () in
    let chroot, socket_path =
      Xenops_sandbox.Varstore_guard.start (Xenops_task.get_dbg task) ~vm_uuid
        ~domid ~paths:[efivars_save_path]
    in
    let args =
      Add.many
        [
          "--domain"
        ; string_of_int domid
        ; "--chroot"
        ; chroot.root
        ; "--depriv"
        ; "--uid"
        ; string_of_int chroot.uid
        ; "--gid"
        ; string_of_int chroot.gid
        ; "--backend"
        ; backend
        ; "--arg"
        ; Printf.sprintf "socket:%s" socket_path
        ]
      >>= fun () ->
      (D.pidfile_path domid |> function
       | None ->
           return ()
       | Some x ->
           Add.many ["--pidfile"; x]
      )
      >>= fun () ->
      Add.many @@ argf "uuid:%s" vm_uuid >>= fun () ->
      on reset_on_boot @@ Add.arg "--nonpersistent" >>= fun () ->
      on restore @@ Add.arg "--resume" >>= fun () ->
      on restore
      @@ Add.many
      @@ argf "resume:%s"
           (Xenops_sandbox.Chroot.chroot_path_inside efivars_resume_path)
      >>= fun () ->
      Add.many
      @@ argf "save:%s"
           (Xenops_sandbox.Chroot.chroot_path_inside efivars_save_path)
    in
    let args = Fe_argv.run args |> snd |> Fe_argv.argv in
    let service = D.start_daemon ~path ~args ~domid () in
    let ready_path = D.pid_path domid in
    wait_path ~pidalive:(D.alive service) ~task ~name ~domid ~xs ~ready_path
      ~timeout:!Xenopsd.varstored_ready_timeout
      ~cancel:(Cancel_utils.Varstored domid) ()

  let stop = D.stop
end

(* TODO: struct and include and uri to uri mapper, etc.
   also xapi needs default backend set
*)
module Swtpm = struct
  module D = SystemdDaemonMgmt (struct
    let name = "swtpm-wrapper"

    let use_pidfile = false

    let pid_path domid = Printf.sprintf "/local/domain/%d/varstored-pid" domid
  end)

  let xs_path ~domid = Device_common.get_private_path domid ^ "/vtpm"

  let state_path =
    (* for easier compat with dir:// mode, but can be anything.
       If we implement VDI state storage this could be a block device
    *)
    Xenops_sandbox.Chroot.Path.of_string ~relative:"tpm2-00.permall"

  let restore ~domid ~vm_uuid state =
    if String.length state > 0 then (
      let path = Xenops_sandbox.Swtpm_guard.create ~domid ~vm_uuid state_path in
      debug "Restored vTPM for domid %d: %d bytes, digest %s" domid
        (String.length state)
        (state |> Digest.string |> Digest.to_hex) ;
      Unixext.write_string_to_file path state
    ) else
      debug "vTPM state for domid %d is empty: not restoring" domid

  let start ~xs ~vtpm_uuid ~index task domid =
    debug "Preparing to start swtpm-wrapper to provide a vTPM (domid=%d)" domid ;
    let exec_path = !Resources.swtpm_wrapper in
    let name = "swtpm" in
    let vm_uuid = Xenops_helpers.uuid_of_domid ~xs domid |> Uuid.to_string in

    let chroot, _socket_path =
      Xenops_sandbox.Swtpm_guard.start (Xenops_task.get_dbg task) ~vm_uuid
        ~domid ~paths:[]
    in
    let tpm_root =
      Xenops_sandbox.Chroot.(absolute_path_outside chroot Path.root)
    in
    (* the uri here is relative to the chroot path, if chrooting is disabled then
       swtpm-wrapper should modify the uri accordingly.
       xenopsd needs to be in charge of choosing the scheme according to the backend
    *)
    let state_uri =
      Filename.concat "file://"
      @@ Xenops_sandbox.Chroot.chroot_path_inside state_path
    in
    let args = Fe_argv.Add.many [string_of_int domid; tpm_root; state_uri] in
    let args = Fe_argv.run args |> snd |> Fe_argv.argv in
    let timeout_seconds = !Xenopsd.swtpm_ready_timeout in
    let execute = D.start_daemon in
    let service =
      {name; domid; exec_path; chroot; args; execute; timeout_seconds}
    in

    let dbg = Xenops_task.get_dbg task in
    let state =
      Varstore_privileged_client.Client.vtpm_get_contents dbg vtpm_uuid
      |> Base64.decode_exn
    in

    let abs_path =
      Xenops_sandbox.Chroot.absolute_path_outside chroot state_path
    in
    if Sys.file_exists abs_path then
      debug "Not restoring vTPM: %s already exists" abs_path
    else
      restore ~domid ~vm_uuid state ;
    let vtpm_path = xs_path ~domid in

    xs.Xs.write
      (Filename.concat vtpm_path @@ string_of_int index)
      (Uuidm.to_string vtpm_uuid) ;

    start_and_wait_for_readyness ~task ~service ;
    (* return the socket path so qemu can have a reference to it*)
    Xenops_sandbox.Chroot.(
      absolute_path_outside chroot (Path.of_string ~relative:"swtpm-sock")
    )

  let suspend ~xs ~domid ~vm_uuid =
    D.stop ~xs domid ;
    Xenops_sandbox.Swtpm_guard.read ~domid ~vm_uuid state_path

  let stop dbg ~xs ~domid ~vm_uuid ~vtpm_uuid =
    debug "About to stop vTPM (%s) for domain %d (%s)"
      (Uuidm.to_string vtpm_uuid)
      domid vm_uuid ;
    let contents = suspend ~xs ~domid ~vm_uuid in
    let length = String.length contents in
    if length > 0 then (
      debug "Storing vTPM state of %d bytes" length ;
      Varstore_privileged_client.Client.vtpm_set_contents dbg vtpm_uuid
        (Base64.encode_string contents)
    ) else
      debug "vTPM state is empty: not storing" ;
    (* needed to save contents before wiping the chroot *)
    Xenops_sandbox.Swtpm_guard.stop dbg ~domid ~vm_uuid
end

module PV_Vnc = struct
  module D = DaemonMgmt (struct
    let name = "vncterm"

    let use_pidfile = false

    let pid_path domid = Printf.sprintf "/local/domain/%d/vncterm-pid" domid
  end)

  let vnc_console_path domid = Printf.sprintf "/local/domain/%d/console" domid

  let vnc_port_path domid =
    Printf.sprintf "/local/domain/%d/console/vnc-port" domid

  let tc_port_path domid =
    Printf.sprintf "/local/domain/%d/console/tc-port" domid

  let pid ~xs domid = D.pid ~xs domid

  (* Look up the commandline args for the vncterm pid; *)
  (* Check that they include the vncterm binary path and the xenstore console
     path for the supplied domid. *)
  let is_cmdline_valid domid pid =
    try
      let cmdline =
        Printf.sprintf "/proc/%d/cmdline" pid
        |> Unixext.string_of_file
        |> Astring.String.cuts ~sep:"\000"
      in
      List.mem !Xc_resources.vncterm cmdline
      && List.mem (vnc_console_path domid) cmdline
    with _ -> false

  let is_vncterm_running ~xs domid =
    match pid ~xs domid with
    | None ->
        false
    | Some p ->
        D.is_running ~xs domid && is_cmdline_valid domid p

  let get_vnc_port ~xs domid =
    if not (is_vncterm_running ~xs domid) then
      None
    else
      try Some (Socket.Port (int_of_string (xs.Xs.read (vnc_port_path domid))))
      with _ -> None

  let get_tc_port ~xs domid =
    if not (is_vncterm_running ~xs domid) then
      None
    else
      try Some (int_of_string (xs.Xs.read (tc_port_path domid)))
      with _ -> None

  let load_args = function
    | None ->
        []
    | Some filename ->
        if Sys.file_exists filename then
          ["-l"; filename]
        else
          []

  exception Failed_to_start

  let vncterm_statefile pid =
    Printf.sprintf "/var/xen/vncterm/%d/vncterm.statefile" pid

  let get_statefile ~xs domid =
    match pid ~xs domid with
    | None ->
        None
    | Some pid ->
        let filename = vncterm_statefile pid in
        if Sys.file_exists filename then
          Some filename
        else
          None

  let save ~xs domid =
    match pid ~xs domid with
    | Some pid ->
        Unix.kill pid Sys.sigusr1 ;
        let filename = vncterm_statefile pid in
        let delay = 10. in
        let start_time = Unix.time () in
        (* wait at most ten seconds *)
        while
          (not (Sys.file_exists filename)) || Unix.time () -. start_time > delay
        do
          debug "Device.PV_Vnc.save: waiting for %s to appear" filename ;
          Thread.delay 1.
        done ;
        if Unix.time () -. start_time > delay then
          debug "Device.PV_Vnc.save: timeout while waiting for %s to appear"
            filename
        else
          debug "Device.PV_Vnc.save: %s has appeared" filename
    | None ->
        ()

  let start ?statefile ~xs ?ip domid =
    debug "In PV_Vnc.start" ;
    let ip = Option.value ~default:"127.0.0.1" ip in
    let l =
      [
        "-x"
      ; Printf.sprintf "/local/domain/%d/console" domid
      ; "-T"
      ; (* listen for raw connections *)
        "-v"
      ; ip ^ ":1"
      ]
      @ load_args statefile
    in
    (* Now add the close fds wrapper *)
    let pid = D.start_daemon ~path:!Xc_resources.vncterm ~args:l ~domid () in
    let path = D.pid_path domid in
    xs.Xs.write path (string_of_int (Forkhelpers.getpid pid)) ;
    Forkhelpers.dontwaitpid pid

  let stop ~xs domid = D.stop ~xs domid
end
