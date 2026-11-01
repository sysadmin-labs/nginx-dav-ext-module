# nginx-dav-ext-module

[![Build&Test][build-test-badge]][build-test-link]
[![WebDAV][dav-badge]][dav-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/build-test.yml
[dav-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/dav_ext.yml/badge.svg
[dav-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/dav_ext.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/freebsd.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-dav-ext-module/actions/workflows/lint.yml

The standard nginx `ngx_http_dav_module` implements only part of WebDAV:
GET, HEAD, PUT, DELETE, MKCOL, COPY and MOVE.  This module adds the missing
methods on top of it, so the two together give a working WebDAV server:

- `PROPFIND` and `OPTIONS`, with the directory listing returned as a
  `multistatus` document;
- `LOCK` and `UNLOCK`, backed by a shared memory lock zone.

## Synopsis

```nginx
http {
    dav_ext_lock_zone zone=davlock:10m timeout=30s;

    server {
        location / {
            root /var/www/dav;

            # the standard module provides these
            dav_methods     PUT DELETE MKCOL COPY MOVE;

            # this module adds these
            dav_ext_methods PROPFIND OPTIONS LOCK UNLOCK;
            dav_ext_lock    zone=davlock;
        }
    }
}
```

## Directives

- `dav_ext_methods [PROPFIND] [OPTIONS] [LOCK] [UNLOCK]`: which of the
  extra methods to handle in this location.
- `dav_ext_lock_zone zone=<name>:<size> [timeout=<time>]`: a shared memory
  zone that holds the locks, declared in the `http` block.
- `dav_ext_lock zone=<name>`: enable `LOCK`/`UNLOCK` in this location
  using that zone.

The module links libxml2 and libxslt (through nginx's `LIBXSLT`), which the
PROPFIND response is built with.

## Building

The standard dav module has to be in the build as well:

```sh
./configure --with-http_dav_module --add-module=/path/to/nginx-dav-ext-module
```

or as a loadable module

```sh
./configure --with-http_dav_module \
    --add-dynamic-module=/path/to/nginx-dav-ext-module
```

with `load_module modules/ngx_http_dav_ext_module.so;` in the main context.

## Testing

```sh
ci/build.sh 1.30.5 /tmp/nginx-test
TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
ci/dav_ext.sh /tmp/nginx-test/sbin/nginx
ci/reload.sh /tmp/nginx-test/sbin/nginx
```

The `t/` suite needs the Perl module `HTTP::DAV`; the nginx core
`Test::Nginx` is vendored under `t/lib`.  `ci/dav_ext.sh` needs only
`curl` and drives the methods end to end, including the lock, unlock and
relock cycle that HTTP::DAV cannot.

## License

BSD 2-Clause, see [LICENSE](LICENSE).
