# Changelog

## 3.0.1 (2026-11-01)

Taken over as a maintained fork of arut/nginx-dav-ext-module, whose newest
tag (3.0.0, 2018) is also the head of its master branch.  This release is
that code, built and tested against current nginx, with the two fixes the
FreeBSD port has carried as local patches folded in.

- PROPFIND no longer hides every dotfile.  A directory entry was dropped
  whenever its name began with a dot, so files such as `.htaccess` never
  appeared in a listing; only `.` and `..` are skipped now (FreeBSD port
  patch; upstream PR #62).
- A directory entry that cannot be stat'd during PROPFIND no longer fails
  the whole request with 500.  `ngx_de_info` failing on one child, such as
  a broken symlink or a file removed mid-listing, is logged and the entry
  skipped, so the rest of the collection is still returned (FreeBSD port
  patch; upstream PR #56/#55).

The bundled suite in `t/` drives the module through HTTP::DAV.  HTTP::DAV
0.50 cannot send UNLOCK, its unlock() issues no request at all, so the lock,
unlock and relock cycle is not asserted through it.  The module does it
correctly, verified with curl and exercised end to end in `ci/dav_ext.sh`.

Valgrind runs against that end-to-end driver, not the Test::Nginx suite: the
driver starts one foreground nginx under valgrind and stops it with QUIT, so
the pools are freed and a leak report would be the module's own; it is clean.
