FROM coredns/coredns:latest

COPY Corefile /
COPY db.example.com /
