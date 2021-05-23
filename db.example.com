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
