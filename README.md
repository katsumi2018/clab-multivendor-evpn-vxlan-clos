# clab-multivendor-evpn-vxlan-clos

Containerlab を使って、マルチベンダー構成の IP Clos 上に EVPN-VXLAN による L2 延伸を構築する検証用リポジトリです。

詳細な構築手順や確認結果は、以下の Qiita 記事にまとめています。

* [BGP Unnumbered + EVPN-VXLAN のマルチベンダー IP Clos を構築してみる](https://qiita.com/k-maki/items/a38d1593a63bb11ee28f)

## 概要

本ラボでは、2 Spine / 4 Leaf の Clos トポロジを Containerlab で構築し、以下の構成を検証します。

```text
Physical : 2 Spine / 4 Leaf Clos
Underlay : BGP Unnumbered
Overlay  : BGP EVPN
DataPlane: VXLAN
Service  : VLAN 100 / VNI 10100
```

各 Leaf 配下の client を同一セグメント `192.168.100.0/24` に配置し、EVPN-VXLAN によって Leaf 間で L2 延伸できることを確認します。

<img width="1042" height="400" alt="image" src="https://github.com/user-attachments/assets/7dcd8be2-a601-41c9-b570-a7efc4d238d7" />

<img width="944" height="481" alt="image" src="https://github.com/user-attachments/assets/ad8f65c4-eb6f-4da7-9d83-aa649c189642" />


## 利用機器

| Node   | NOS                   |
| ------ | --------------------- |
| spine1 | Arista cEOS           |
| spine2 | Arista cEOS           |
| leaf1  | VyOS                  |
| leaf2  | Arista cEOS           |
| leaf3  | SONiC VS              |
| leaf4  | Juniper cJunosEvolved |

## 利用技術

* Containerlab
* BGP Unnumbered
* MP-BGP EVPN
* VXLAN
* VLAN/VNI による L2 延伸
* EVPN Route Type 2 による MAC 学習
* Spine を Route Reflector とした EVPN 構成

## L2 延伸用パラメータ

```text
VLAN: 100
VNI : 10100
RT  : 10100:10100
```
