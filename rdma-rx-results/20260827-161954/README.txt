rdma-rx-size benchmark (smoke mode)
===================================
git commit : 9ab2c530f66c777081705101cc375be449cb55e4
started at : 2026-08-27T16:19:54+08:00
RDMA       : rxe_dummy on dummy0 (10.200.0.1/24), port 16379
layout     : environment.txt, summary.csv, raw/ (per-run benchmark CSV+stderr,
             build.log, rdma-res snapshots), server-logs/ (one log per server
             instance; multiple instances per rx mean teardown crashes occurred
             and the server was restarted - measurements are unaffected)

payload_gbps = rps * value_size * 8 / 1e9
  -> PAYLOAD-ONLY estimate. It excludes RESP protocol framing, RDMA protocol
     headers and memory-registration costs, so it is NOT wire throughput.

The RDMA transport here is software RXE (rdma_rxe) on a dummy netdev.
Results validate protocol mechanics, harness behaviour and relative trends
only. They say NOTHING about physical (100G) RDMA NIC performance.
