#!/usr/bin/env python3
"""App Store Connect API 最小客户端（查 App 记录 / 构建状态 / Bundle ID）。

用法：python3 Scripts/asc_api.py GET "/v1/builds?filter[app]=6808890012"
      python3 Scripts/asc_api.py POST /v1/betaGroups '{"data":{...}}'

密钥读 ~/.appstoreconnect/private_keys/AuthKey_<KID>.p8，只依赖 cryptography，不用装 PyJWT。
ASC_KEY_ID / ASC_ISSUER_ID 环境变量可覆盖默认密钥（CI 用 App Manager 权限的那把）。
"""
import json, sys, time, base64, urllib.request, os
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
KID=os.environ.get("ASC_KEY_ID","U4QUAH53N9"); ISS=os.environ.get("ASC_ISSUER_ID","8f41f165-4ec4-46b7-a529-634b024931f6")
key=serialization.load_pem_private_key(open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KID}.p8"),"rb").read(),None)
b64=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
h=b64(json.dumps({"alg":"ES256","kid":KID,"typ":"JWT"}).encode()); now=int(time.time())
p=b64(json.dumps({"iss":ISS,"iat":now,"exp":now+1200,"aud":"appstoreconnect-v1"}).encode())
sig=key.sign(f"{h}.{p}".encode(),ec.ECDSA(hashes.SHA256())); r,s=decode_dss_signature(sig)
tok=f"{h}.{p}."+b64(r.to_bytes(32,"big")+s.to_bytes(32,"big"))
def call(method,path,body=None):
    req=urllib.request.Request("https://api.appstoreconnect.apple.com"+path,method=method,data=json.dumps(body).encode() if body else None,
        headers={"Authorization":"Bearer "+tok,"Content-Type":"application/json"})
    try:
        resp=urllib.request.urlopen(req); body=resp.read()
        # PATCH relationships / DELETE 返回 204 无正文
        return json.loads(body) if body else {"status": resp.status}
    except urllib.error.HTTPError as e: return {"error":e.code,"body":e.read().decode()}
if __name__=="__main__":
    m,path=sys.argv[1],sys.argv[2]; body=json.loads(sys.argv[3]) if len(sys.argv)>3 else None
    print(json.dumps(call(m,path,body),indent=1,ensure_ascii=False))
