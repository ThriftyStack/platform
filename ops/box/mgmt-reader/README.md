# Management reader on the ops box

The ops box reaches the management API at `https://10.0.10.83:6443` over WARP.
It uses the `box-reader` ServiceAccount in `operator-access`. Tokens last 24
hours, are bound to the Secret `box-reader-anchor`, and renew themselves.
Deleting that Secret revokes every bound token.

## Setup

1. Merge the platform change and let Argo sync the `operator-access` Application.
2. On the box, create `/home/box/.kube/mgmt-reader/` mode `700`.
3. Copy `kubeconfig.tmpl` to `/home/box/.kube/mgmt-reader/config`.
4. Put the management API CA in `/home/box/.kube/mgmt-reader/ca.crt`.
5. Put the enrollment file at `/home/box/.kube/mgmt-reader/warp-enroll.env`
   as `KEY=VALUE` lines, mode `600`. Do not print it.
6. Put the first token at `/home/box/.kube/mgmt-reader/token`, mode `600`.
   Do not paste the token into chat, logs, or git.
7. Run `./warp-up.sh`. It starts `warp-svc` in the background with no systemd,
   appends to `warp.log`, and waits until `10.0.10.83:6443` accepts a connection.

## Renewal

An external scheduler runs `renew.sh` every 6 hours. The script uses the
current token to mint a new 24-hour token bound to `box-reader-anchor`, checks
`kubectl auth whoami`, and replaces `/home/box/.kube/mgmt-reader/token` only
after that check. The file stays mode `600`. The token is never printed.
If the current token is expired, the script exits non-zero and leaves the
file in place.

## Revoke

1. Delete the Secret `operator-access/box-reader-anchor`. Tokens bound to it
   stop working. Argo may recreate an empty Secret; the new object has a new
   UID, so the previous tokens stay invalid.
2. Revoke the Access token.
3. Remove the device.

## Recovery

Egor re-mints from his Mac once `box-reader-anchor` exists again. Write the
stdout to the token file on the box with mode `600`. Do not commit it.

```bash
umask 077
kubectl --kubeconfig ~/.kube/config-mgmt create token box-reader \
  -n operator-access \
  --duration=24h \
  --bound-object-kind=Secret \
  --bound-object-name=box-reader-anchor
```

Export the API CA to the box the same way. Do not commit the certificate.

```bash
kubectl --kubeconfig ~/.kube/config-mgmt config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /home/box/.kube/mgmt-reader/ca.crt
```
