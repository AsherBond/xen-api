(*
 * Copyright (c) Citrix Systems Inc.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let use_mtime () = Mtime.Span.to_uint64_ns (Mtime_clock.elapsed ())

let use_timeofday () = Int64.of_float (Unix.gettimeofday () *. Mtime.s_to_ns)

let ns =
  try
    Mtime_clock.now () |> ignore;
    use_mtime
  with Sys_error e -> begin
      Logging.warn "Error: %s. No monotonic clock source: falling back to calendar time" e;
      use_timeofday
    end

include Unix
let time = gettimeofday

let s () = Int64.to_float (ns ()) /. 1e9
