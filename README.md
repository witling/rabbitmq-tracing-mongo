An opinionated tracing plugin for RabbitMQ management. Build it like
any other plugin. After installation you should see a "Tracing" tab in
the management UI.

# Configuration

There is three configuration options:

- `mongo_ip`: The MongoDB ip address for saving the tracing data.
- `mongo_port`: The MongoDB port for saving the tracing data.
- `username`: name of the user as which to create queues and bind to the tracing exchange. Obviously this user will need to exist and have permission to do those things.

# HTTP API

```
GET            /api/traces
GET            /api/traces/<vhost>
GET PUT DELETE /api/traces/<vhost>/<name>
```

Example for how to start a trace:

``` bash
$ curl -i -u guest:guest -H "content-type:application/json" -XPUT \
  http://localhost:55672/api/traces/%2f/my-trace \
  -d'{"pattern":"#"}'
```

# Installation

This plugin needs emongo.

``` bash
	cd plugins
	git clone https://github.com/JacobVorreuter/emongo
	cd emongo
	make
```

Or clone the emongo-wrapper
	
``` bash
	git clone https://github.com/doubaokun/emongo-wrapper
```

Add the following to config file:

``` erlang
	{env,[{username,<<"guest">>},
                    {mongo_ip,"192.168.49.64"},
                    {mongo_port,27017}]}
```