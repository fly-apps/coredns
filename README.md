# Authoritative DNS on Fly

In this guide we're going to get a globally-distributed authoritative, redundant DNS service using [CoreDNS](https://coredns.io/) set up on fly.io in a few simple steps. We assume that you currently hold a domain which you would like to host nameservers for. In the rest of this guide we will use the domain `example.com`, which you should be able to substitute with your own domain.

## A quick aside

You may be wondering "what is authoritative DNS?" and "what is fly.io and why would you use it?".

### What is authoritative DNS?

The Domain Name System (DNS) is a distributed system of servers which store mappings from names to IP addresses. Some of these servers store the "source truth" for a name to IP mapping, these are called authoritative nameservers. Other servers answer client's requests by finding the right authoritative nameservers to speak to and get the correct answers, these are called resolvers. You may be familiar with the Google and Cloudflare resolvers which have the IPs 8.8.8.8 and 1.1.1.1 respectively. Cloudflare has good [documentation](https://www.cloudflare.com/learning/dns/dns-server-types/#recursive-resolver) on DNS server types which goes a little bit more in-depth.

### Why fly.io?

A good authoritative DNS server responds quickly to requests (i.e. has low latency). For global services, latency is primarily a function of distance between client and server. Achieving global low-latency means 1) having servers physically close to clients all around the world and 2) setting up complex infrastructure like [anycast](https://fly.io/docs/reference/architecture/#bgp-anycast) which allows physical servers all around the world to share the same IP address. This is both expensive and technically hard to do. With fly.io this functionality is baked right in, which is why it's such a good fit for a service like DNS.

## Overview

In this guide, we will configure a DNS service, run the service on fly.io, and configure the domain registrar so that the DNS service that we have configured is used to obtain DNS records for our domain.

DNS was designed with redundancy in mind, so we must provide two nameservers. We will use the names `ns1.example.com` and `ns2.example.com` (you're free to call them what you like). In order to be reachable on the internet, these nameservers will also need public IP addresses.

Due to the order of the dependencies, we will go through the configuration in the following order:

1) Fly.io app and public IPs

2) Your domain registrar

3) CoreDNS (including DNS zone file)

4) Fly.io deployment
   
5) Global distribution

## Fly.io

We will configure one app to provide our DNS service which we call `fly-coredns` for this example. We assume that you have already created an account with fly.io and have `flyctl` installed locally. If you have not done this yet, please refer to the [Hands On with Fly](https://fly.io/docs/hands-on/start/) documentation.

We will get started with the `flyctl init` command, which will create and register our app on the fly.io platform. Additionally, it will generate a `fly.toml` configuration file which tells fly how this app should be deployed. During the init process, ensure that you select `Dockerfile` for the builder, and `53` for the internal port:

```
> fly init fly-coredns-1

Selected App Name: fly-coredns-1

Automatically selected personal organization: <our organization>

? Select builder: Dockerfile
    (Do not set a builder and use the existing Dockerfile)
? Select Internal Port: 53
New app created
  Name         = fly-coredns-1
  Organization = personal
  Version      = 0
  Status       =
  Hostname     = <empty>

App will initially deploy to ewr (Secaucus, NJ (US)) region

Wrote config file fly.toml
```

The generated `fly.toml` config contains a number of entries which we do not need. We will need to make the following changes:

- In the `services` stanza, change `protocol` from `"tcp"` to `"udp"`
- Ensure that only one `services.ports` entry is present, with no `handlers` entry, and port 53
- We can optionally remove the stanzas for `services.concurrency` and `services.tcp_checks` as they are not needed

In the end, our minimal `fly.toml` config should look as follows:

```
app = "fly-coredns"

kill_signal = "SIGINT"
kill_timeout = 5

[[services]]
  internal_port = 53
  protocol = "udp"

  [[services.ports]]
    port = 53
```

This defines the name of our app, and configures the mapping of the external UDP port 53 to the internal port 53.

Next we will need our two IP addresses. We can allocate an ipv4 address with the `flyctl ips allocate-v4` command. We will run it twice to allocate two addresses:

```
> flyctl ips allocate-v4

TYPE ADDRESS        CREATED AT
v4   213.188.208.61 just now

> flyctl ips allocate-v4

TYPE ADDRESS         CREATED AT
v4   213.188.209.159 just now
```

We will use the first IP `213.188.208.61` for `ns1.example.com`, and `213.188.209.159` for `ns2.example.com`.

For now, we have configured all we can with fly. Now we will move on to configuring the domain registrar.

## Domain registrar

We will need to configure two parameters with our domain registrar:
1) The nameservers 
2) Glue records which provide a binding from nameservers to IP

### Nameservers
The registrar should provide a configuration field for the nameservers which we have defined: `ns1.example.com` and `ns2.example.com`. We will configure that now.

### Glue records

You may have noticed that if `ns1.example.com` is supposed to serve name-to-IP mappings for `example.com`, and `ns1.example.com` is itself part of `example.com`, how should a client find the IP of `ns1.example.com`? The answer is "glue records", which provide an explicit name-to-IP mapping for your nameservers. These are configured with your registrar and allow the circular dependency to be broken.

The registrar should provide a way to configure this mapping. We will configure the hostname and IP pair for each of the nameservers as follows:

```
hostname         IP
---
ns1.example.com  213.188.208.61
ns2.example.com  213.188.209.159
```

## CoreDNS

While CoreDNS offers a number of methods to configure the DNS records that it will serve, we will use the simplest approach: a "traditional" DNS [zone file](https://en.wikipedia.org/wiki/Zone_file). We will require two configuration files: the first is the `Corefile`, a config for CoreDNS itself, the second is the DNS zone file.

The `Corefile` contains the following entry:

```
example.com {
    file db.example.com
    log
}
```

This tells CoreDNS that we will serve the domain (also called zone) `example.com` from the file `db.example.com`, and that we want CoreDNS to log DNS requests for this zone.

The second file is the zone file for the `example.com` zone, it is named `db.example.com` and looks as follows:

```
$ORIGIN example.com.
$TTL 86400
@	IN	SOA	ns1.example.com.	hostmaster.example.com. (
		2021052301 ; serial
		21600      ; refresh after 6 hours
		3600       ; retry after 1 hour
		604800     ; expire after 1 week
		86400 )    ; minimum TTL of 1 day
;
;
	IN	NS	ns1.example.com.
	IN	NS	ns2.example.com.
ns1	IN	A	213.188.208.61
ns2	IN	A	213.188.209.159
```

The DNS zone file format is a little cryptic, and we won't go into the exact details of what all of the pieces do. This example is a bare-bones zone file which simply configures the start of authority (SOA) for the zone, and nameserver (NS) and associated address (A) records for the zone, which we have configured with the IPs that we generated above.

## Fly.io deployment

We previously told fly that we would be deploying our application with a Dockerfile. Let's quickly put together a Dockerfile which gets our DNS server running, thanks to smart defaults in the `coredns/coredns` docker image, this is quite short:

```
FROM coredns/coredns:latest

COPY Corefile /
COPY db.example.com /
```

Now that we have a Dockerfile, we are ready to deploy our app to fly with the `flyctl deploy` command:

```
> flyctl deploy

Deploying fly-coredns
==> Validating app configuration
--> Validating app configuration done
Services
UDP 53 ⇢ 53
==> Creating build context
--> Creating build context done
==> Building image with Docker
[+] Building 0.2s (7/7) FINISHED
 => [internal] load remote build context
 => copy /context /
 => [internal] load metadata for docker.io/coredns/coredns:latest
 => CACHED [1/3] FROM docker.io/coredns/coredns:latest
 => [2/3] COPY Corefile /
 => [3/3] COPY db.example.com /
 => exporting to image
 => => exporting layers
 => => writing image sha256:301baf5bfb4c86a68d4c4ae621725b0a532f9acacde7ca9765a3fcb956dd963c
 => => naming to registry.fly.io/fly-coredns:deployment-1621801247
--> Building image done
==> Pushing image to fly
The push refers to repository [registry.fly.io/fly-coredns]
c6c1a406eb52: Pushed
1e8f1ce7bcac: Pushed
85c53e1bd74e: Pushed
225df95e717c: Pushed
deployment-1621801247: digest: sha256:79e3b738c071b3cb47308c9a4a90d41bcb7f9772c30b71c26413fbcb45b3979b size: 1153
--> Pushing image done
Image: registry.fly.io/fly-coredns:deployment-1621801247
Image size: 44 MB
==> Creating release
Release v0 created

You can detach the terminal anytime without stopping the deployment
Monitoring Deployment
```

Let's see if the app is working. With `flyctl logs` we can tail the logs from the running application. We will run it in a separate console window so that we can interact with our app and see the output:

```
> flyctl logs --app fly-coredns

2021-05-23T20:21:02.284133255Z runner[ff673359] ewr [info] Starting instance
2021-05-23T20:21:02.311505446Z runner[ff673359] ewr [info] Configuring virtual machine
2021-05-23T20:21:02.312505898Z runner[ff673359] ewr [info] Pulling container image
2021-05-23T20:21:03.591466128Z runner[ff673359] ewr [info] Unpacking image
2021-05-23T20:21:03.881831386Z runner[ff673359] ewr [info] Preparing kernel init
2021-05-23T20:21:04.286519772Z runner[ff673359] ewr [info] Configuring firecracker
2021-05-23T20:21:04.304557252Z runner[ff673359] ewr [info] Starting virtual machine
2021-05-23T20:21:04.446225238Z app[ff673359] ewr [info] Starting init (commit: cc4f071)...
2021-05-23T20:21:04.458956467Z app[ff673359] ewr [info] Running: `/coredns` as root
2021-05-23T20:21:04.462773235Z app[ff673359] ewr [info] 2021/05/23 20:21:04 listening on [fdaa:0:2aad:a7b:ab3:ff67:3359:2]:22 (DNS: [fdaa::3]:53)
2021-05-23T20:21:04.563043459Z app[ff673359] ewr [info] example.com.:53
2021-05-23T20:21:04.563270892Z app[ff673359] ewr [info] CoreDNS-1.8.3
2021-05-23T20:21:04.563633111Z app[ff673359] ewr [info] linux/amd64, go1.16, 4293992
```

Now we'll use `dig` to make a query directly to the DNS server that we have configured:

```
> dig @213.188.208.61 ns1.example.com

; <<>> DiG 9.10.6 <<>> @213.188.208.61 ns1.example.com
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 52472
;; flags: qr aa rd; QUERY: 1, ANSWER: 1, AUTHORITY: 2, ADDITIONAL: 1
;; WARNING: recursion requested but not available

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
;; QUESTION SECTION:
;ns1.example.com.		IN	A

;; ANSWER SECTION:
ns1.example.com.	86400	IN	A	213.188.208.61

;; AUTHORITY SECTION:
example.com.		86400	IN	NS	ns1.example.com.
example.com.		86400	IN	NS	ns2.example.com.

;; Query time: 130 msec
;; SERVER: 213.188.208.61#53(213.188.208.61)
;; WHEN: Sun May 23 22:26:00 CEST 2021
;; MSG SIZE  rcvd: 155
```

The output indicates that our DNS server is correctly serving the DNS records we've configured. Success!

In our logging window, we also see the following entry, indicating that our fly DNS service served the request:

```
2021-05-23T20:22:10.078954676Z app[ff673359] ewr [info] [INFO] 212.51.143.89:60891 - 48514 "A IN ns1.example.com. udp 44 false 4096" NOERROR qr,aa,rd 144 0.000191369s
```

If the glue records have been correctly configured then we should be able to get the A record for `ns1.example.com` with `dig ns1.example.com`

```
> dig ns1.example.com

; <<>> DiG 9.10.6 <<>> ns1.example.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 47134
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
;; QUESTION SECTION:
;ns1.example.com.			IN	A

;; ANSWER SECTION:
ns1.example.com.		9466	IN	A	213.188.208.61

;; Query time: 38 msec
;; SERVER: 192.168.1.1#53(192.168.1.1)
;; WHEN: Sun May 23 23:50:12 CEST 2021
;; MSG SIZE  rcvd: 58
```

You may be wondering: "what about those glue records, how can we distinguish between the glue record response and the response from `ns1.example.com`?". This is a valid question. The first indicator is that we see the A record in the `ANSWER SECTION` of the response. This answer is an authoritative answer from our DNS server.

To see the difference to the glue records, let's take a look at the glue record. To get the glue record, we will directly ask the `.com.` nameserver for its entry for `ns1.example.com`. First, we will determine the nameserver for the `.com` TLD with `dig NS com.`:

```
> dig NS com.

; <<>> DiG 9.10.6 <<>> NS com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 2114
;; flags: qr rd ra; QUERY: 1, ANSWER: 13, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;com.				IN	NS

;; ANSWER SECTION:
com.			167343	IN	NS	a.gtld-servers.net.
com.			167343	IN	NS	b.gtld-servers.net.
com.			167343	IN	NS	c.gtld-servers.net.
com.			167343	IN	NS	d.gtld-servers.net.
com.			167343	IN	NS	e.gtld-servers.net.
com.			167343	IN	NS	f.gtld-servers.net.
com.			167343	IN	NS	g.gtld-servers.net.
com.			167343	IN	NS	h.gtld-servers.net.
com.			167343	IN	NS	i.gtld-servers.net.
com.			167343	IN	NS	j.gtld-servers.net.
com.			167343	IN	NS	k.gtld-servers.net.
com.			167343	IN	NS	l.gtld-servers.net.
com.			167343	IN	NS	m.gtld-servers.net.
```

We see that there are a handful of nameservers to choose from. Let's directly ask the first .com nameserver for its entry for `example.com.` with `dig @a.gtld-servers.net. NS example.com.`:

```
> dig NS @a.gtld-servers.net. example.com.

; <<>> DiG 9.10.6 <<>> NS @a.gtld-servers.net. example.com.
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 49009
;; flags: qr rd; QUERY: 1, ANSWER: 0, AUTHORITY: 4, ADDITIONAL: 9
;; WARNING: recursion requested but not available

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
;; QUESTION SECTION:
;example.com.			IN	NS

;; AUTHORITY SECTION:
example.com.		10800	IN	NS	ns1.example.com.
example.com.		10800	IN	NS	ns2.example.com.

;; ADDITIONAL SECTION:
ns1.example.com.		3600	IN	A	213.188.208.61
ns2.example.com.		3600	IN	A	213.188.209.159

;; Query time: 62 msec
;; SERVER: 192.5.6.30#53(192.5.6.30)
;; WHEN: Sun May 23 23:58:09 CEST 2021
;; MSG SIZE  rcvd: 287
```

The name-to-IP mappings (address or A records) associated with the glue record are returned in the `ADDITIONAL SECTION` by the TLD nameserver, these are not authoritative answers which the nameserver is providing, but additional information. These are the glue records.

## Global distribution

You may have noticed that when we ran `flyctl init`, we saw the following output: `App will initially deploy to ewr (Secaucus, NJ (US)) region`. So it looks like our app is only running in one place in the world. What about the globally-distributedness that we were promised? Let's make our app distributed and run all around the world.

With `flyctl platform regions` we can get an inventory of the available locations that our could run app in:

```
> flyctl platform regions

CODE NAME                         GATEWAY
ams  Amsterdam, Netherlands
atl  Atlanta, Georgia (US)
cdg  Paris, France
dfw  Dallas 2, Texas (US)
ewr  Secaucus, NJ (US)
fra  Frankfurt, Germany
hkg  Hong Kong
iad  Ashburn, Virginia (US)       ✓
lax  Los Angeles, California (US)
lhr  London, United Kingdom       ✓
nrt  Tokyo, Japan
ord  Chicago, Illinois (US)       ✓
scl  Santiago, Chile
sea  Seattle, Washington (US)
sin  Singapore                    ✓
sjc  Sunnyvale, California (US)   ✓
syd  Sydney, Australia            ✓
yyz  Toronto, Canada
```

Let's get coverage on as many continents as possible by running our DNS app in Amsterdam, New Jersey, Chile, Singapore, and Sydney:

```
> flyctl regions add ams ewr scl sin syd

Region Pool:
ams
ewr
scl
sin
syd
Backup Region:
atl
dfw
fra
hkg
iad
lhr
nrt
vin
```

Now our app will automatically run in the best region for the client which is accessing it, but there will still only be one instance of our app running (the default configuration). We can ensure global coverage by scaling our app up to as many regions as we have configured with `flyctl scale count 5` (note: this doesn't guarantee that we have one instance in each region).

We can check on the status of our app with `flyctl status`:

```
> flyctl status

App
  Name     = fly-coredns
  Owner    = personal
  Version  = 5
  Status   = running
  Hostname = fly-coredns.fly.dev

Deployment Status
  ID          = 3b5815ad-09d8-2724-5107-6b6227a89dee
  Version     = v5
  Status      = successful
  Description = Deployment completed successfully
  Instances   = 5 desired, 5 placed, 5 healthy, 0 unhealthy

Instances
ID       VERSION REGION DESIRED STATUS  HEALTH CHECKS RESTARTS CREATED
fb294628 5       ewr    run     running               0        5m10s ago
c09d2aaa 5       syd    run     running               0        5m47s ago
b2df948f 5       fra(B) run     running               0        6m24s ago
97f4852a 5       sin(B) run     running               0        6m58s ago
77ab4c5c 5       scl    run     running               0        7m30s ago
```

## Conclusion

We've seen how to quickly stand up a DNS service based on fly.io, including registrar configuration, and how make the service scale globally. As a next step you might want to configure futher A records for the services that you will host on your domain. Perhaps you need globally-distributed static html [server](https://fly.io/docs/getting-started/static/)? Otherwise you might want to activate the [prometheus plugin](https://coredns.io/plugins/metrics/) for CoreDNS and scrape the metrics using fly's built-in metrics [support](https://fly.io/docs/reference/metrics/#welcome-message).
