# MIM JIT testbed

This Docker Compose env allows to run a small scale MongooseIM load test
on a local machine.

Let's bring the environment up:

```
docker-compose up -d
```

The test startup is not completely automated, so we have to do some steps manually.

The first step is to create users on MongooseIM side - the Mnesia
directory is mounted from the host machine, so this only has to be done
once (see `docker-compose.yml` for details):

```
host$ docker exec -it bash
mongooseim-1$ /usr/lib/mongooseim/bin/mongooseimctl debug
```

In the remote shell, the number of currently registered users can be checked with:

```
ets:info(passwd, size).
```

If it's greater than 0 and matches our requirements for the test, we're fine already.
Otherwise, the following snippet can be used to create users:

```
MaxUsers = 1000.
Creds = [ {<<"user_", (integer_to_binary(I))/bytes>>, <<"password_", (integer_to_binary(I))/bytes>>}
          || I <- lists:seq(1, MaxUsers) ].
[ ejabberd_auth:try_register(jid:make(U, <<"localhost">>, <<>>), P) || {U, P} <- Creds ].
```

The number of logged in users can be checked with:

```
ets:info(session, size).
```

At this point it's going to be 0, but this snippet is handy during the load test.

In another shell, let's attach to the Amoc container:

```
host$ docker exec -it amoc-1 bash
amoc-1$ /home/amoc/amoc/bin/amoc remote_console
```

In the Amoc remote console we're ready to start the test:

```
l(one2one).  %% the release runs in embedded mode, we have to load the test scenario manually
amoc_local:do(one2one, 1, 1000).  %% run the test for user IDs 1 to 1000 inclusive
```

From now, the number of users logged into MongooseIM should start growing
(that's when the `ets:info(session, size)` comes in handy).


## Troubleshooting

### Is MongooseIM up and accepting XMPP connections?

We can telnet from the host machine or from Amoc to check that:

```
$ telnet localhost 5222
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' id='dda05b758b960d35' from='localhost' version='1.0'><stream:error><xml-not-well-formed xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error></stream:stream>Connection closed by foreign host.
$
```

After `Escape character is '^]'.` we have to send anything on the
connection, so type `а` or `Ctrl-D` as the end-of-file. This will make the
server respond with `xml-not-well-formed` error, but we have a proof that it's up
and running.

### Watch MongooseIM logs

Watch and follow MongooseIM logs:

```
docker logs -f mongooseim-1
```

Enable verbose logging in the MongooseIM remote console:

```
mongoose_logs:set_global_loglevel(debug).
mongoose_logs:set_global_loglevel(info).
mongoose_logs:set_global_loglevel(error).  %% switches back to the default
```
