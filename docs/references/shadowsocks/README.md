# Shadowsocks 官方规范存档

- 来源：
  - https://shadowsocks.org/doc/aead.html
  - https://shadowsocks.org/doc/sip002.html
  - https://www.rfc-editor.org/rfc/rfc1928.txt
- 存档日期：2026-10-20
- 说明：官方页面/文本已原样保存（aead.html / sip002.html / rfc1928.txt），以下为关键摘录。

## AEAD（aead.html）

- 主密钥可由用户直接输入，或按 OpenSSL 的 EVP_BytesToKey 从密码派生。
- 每个连接使用随机 salt，经 HKDF_SHA1(key, salt, info) 派生子密钥；info 必须为字符串 "ss-subkey"。
- TCP 流 = 随机 salt + 若干个 AEAD chunk。
- chunk 的 payload length 为 2 字节大端无符号整数，上限 0x3FFF（高两位保留为 0）；payload 最大 16*1024-1 字节。
- 每个 chunk 需要两次 AEAD 操作：一次加密长度，一次加密 payload；nonce 从 0 开始，按无符号小端整数递增。
- AEAD ciphers：AEAD_AES_128_GCM、AEAD_AES_256_GCM、AEAD_CHACHA20_POLY1305。

## 地址头

AEAD 页面未重复地址格式；SS 的 TCP 目标地址沿用 SOCKS5（RFC 1928）的 ATYP + DST.ADDR + DST.PORT 格式：

- ATYP = 0x01：IPv4，4 字节地址；
- ATYP = 0x03：域名，1 字节长度 + 域名；
- ATYP = 0x04：IPv6，16 字节地址；
- 随后 2 字节大端端口。

## SIP002（sip002.html）

- ss:// URI 的基本形式为 ss://BASE64(method:password)@host:port#tag；
- 可选 plugin 查询参数；本项目当前配置的 34 个 SS 节点均无 plugin。
- 具体解析以实现时官方页面为准；本项目优先使用本地 YAML 导入，不依赖 URI。

## 注意

- 以上为关键摘录，完整内容见同目录原始文件。
- 任何实现细节以官方页面/规范为准；不把节点密码、完整配置写入仓库。
