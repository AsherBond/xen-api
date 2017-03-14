(*
 * Copyright (C) Citrix Systems Inc.
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

type 'a t = 'a Iteratees.Iteratee(Lwt).t =
  | IE_done of 'a
  | IE_cont of Iteratees.err option * (Iteratees.stream -> ('a t * Iteratees.stream) Lwt.t)

(** Really write a string to a file descriptor - repeats until the whole
    string is done *)
val really_write : Lwt_unix.file_descr -> string -> unit Lwt.t

(** Read from an Lwt fd and send the chunks to an iteratee *)
val lwt_fd_enumerator : Lwt_unix.file_descr -> 'a t -> 'a t Lwt.t

(** Read from a names file and send the chunks to an iteratee *)
val lwt_enumerator : string -> 'a t -> 'a t Lwt.t

exception Host_not_found of string

(** given a host and a port, open a TCP connection and return a connected
    file descriptor *)
val open_connection_fd : string -> int -> Lwt_unix.file_descr Lwt.t

