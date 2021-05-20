# ubuntu4atlas

为Atlas200DK生成一个干净的Ubuntu系统。

未实现开发环境迁移，现在只是个8核Linux Box。

## 支持的系统

- 18.04

## HowTo

典型用例

```
./u4a.sh -i ubuntu-18.04.5-server-arm64.iso -o system.img \
-m "https://mirrors.ustc.edu.cn/ubuntu-ports/ \
-n"
```

写入该镜像后需要手动扩展分区。

