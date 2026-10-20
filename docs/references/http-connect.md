# HTTP CONNECT 参考（RFC 9110 §9.3.6）

- 来源：https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6
- 存档日期：2026-10-20
- 说明：RFC 9110 全文较大，未逐字全文存档；以下为该节关键语义摘要，完整内容以 RFC 原文为准。

## 关键语义

- 请求使用 authority-form：CONNECT <host>:<port> HTTP/1.1，并携带 Host: <host>:<port>。
- 任何 2xx 响应表示隧道已建立；非 2xx 表示失败（代理可返回 407 等）。
- 2xx 响应头结束后，连接立即转为字节隧道；代理不得再按 HTTP 消息解析后续字节。
- HTTP/1.1 的 CONNECT 请求没有内容；客户端在收到 2xx 后才发送隧道数据。
- 代理需要把目标主机的 DNS/连接错误映射为非 2xx（实现中统一返回 502）。

## 用途

- 本地前置代理对外部 HTTP/HTTPS 代理的上游链（本项目的 external upstream）。
- RFC 链接与本节摘要作为实现依据；不引入新的系统 API。
