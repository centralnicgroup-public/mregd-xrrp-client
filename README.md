# mregd

mregd is a Perl daemon that acts as an XRRP client proxy: it accepts local client connections, authenticates them, and relays their commands to a remote XRRP registry backend over a persistent SSL session.

## Structure

| Path | Role |
| --- | --- |
| `mregd.pl` | The daemon itself (a `Net::Server::PreFork` service) |
| `mregd.conf` | Example configuration file |
| `cpanfile` | Perl module dependencies, for `cpanm --installdeps .` |
| `Dockerfile` | Builds a `mregd:latest` container image |
| `docker-compose.yml` | Example compose file to run mregd as a container |

## Standalone usage

### Install dependencies

Using cpanminus:

```
$ cpanm --installdeps .
```

Or via apt (Debian/Ubuntu):

```
$ apt-get install perl libio-socket-ssl-perl libnet-server-perl
```

### Configure

By default, mregd.pl reads `mregd.conf` from the same directory as the script itself, so no absolute install path is required. Just edit `mregd.conf` in place (or wherever you check out this repository):

Edit `mregd.conf` and fill in at least `mregd_login`, `mregd_password`, `mregd_socket_username`, and `mregd_socket_password` (see the [Configuration reference](#configuration-reference) below).

A different config path can be used instead, via `--conf_file=/path/to/mregd.conf` or the `CONF_FILE` environment variable.

### Run

```
$ ./mregd.pl foreground
```

Other supported commands: `start` (background daemon), `stop`, `restart`, `debug` (foreground with verbose logging).

## Docker

### Build

```
$ docker build -t mregd:latest .
```

### Run

```
$ docker run -it \
    -e MREGD_XRRP_LOGIN=registrar \
    -e MREGD_XRRP_PASSWORD="password" \
    -e MREGD_XRRP_HOST=xrrp-ote.rrpproxy.net \
    -e MREGD_XRRP_PORT=2001 \
    -e MREGD_SOCKET_USERNAME=user \
    -e MREGD_SOCKET_PASSWORD=pass \
    -p 6490:6490 \
    mregd:latest
```

### Docker Compose

```
$ docker-compose up -d
```

uses the provided `docker-compose.yml`, which builds the image and starts the container with the same environment variables shown above, publishing port 6490.

## Configuration reference

Config file keys can be set directly in `mregd.conf`, or overridden by the listed environment variable.

### Required

| Config key | Env var override |
| --- | --- |
| `mregd_login` | `MREGD_XRRP_LOGIN` |
| `mregd_password` | `MREGD_XRRP_PASSWORD` |
| `mregd_host` | `MREGD_XRRP_HOST` |
| `mregd_port` | `MREGD_XRRP_PORT` |
| `mregd_socket_username` | `MREGD_SOCKET_USERNAME` |
| `mregd_socket_password` | `MREGD_SOCKET_PASSWORD` |

### Optional

| Config key | Env var override | Notes |
| --- | --- | --- |
| `port` | `MREGD_SOCKET_PORT` | Local listen address for clients, e.g. `localhost:6490|tcp` or `/tmp/mregd.service|unix` |
| `max_servers` | `MAX_SERVERS` | Number of pre-forked sessions to the backend |
| `mregd_keepalive_interval` | `MREGD_KEEPALIVE_INTERVAL` | Seconds between keepalive requests to the backend |
| `pid_file` | `PID_FILE` | Used with the `start`/`stop`/`restart` commands |
| `log_level` | `LOG_LEVEL` | |
| `log_file` | — | Log destination; omit to log to STDOUT/STDERR |
| `conf_file` | `CONF_FILE` | Path to the config file itself (default: `mregd.conf` next to `mregd.pl`) |
| `min_servers` | `MIN_SERVERS` | |
