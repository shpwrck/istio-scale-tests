# hub-mesh-push-secrets

Hub-side ESO objects, one release per mesh member (from the `hub-mesh-push-secrets`
ApplicationSet):

- `push-cacerts-<member>` pushes Istio `cacerts` to that member's `istio-system`.
- `push-remote-secret-<member>` pushes `istio-remote-secret-<member>` to every member's
  `istio-system`.

Removing a member does not delete what was pushed (ESO `deletionPolicy` stays `None`), and
istiod keeps that cluster until its remote secret is deleted: the wiring gate on each remaining
member reads NotReady, naming the secret, until then. Delete it from each remaining member:

```bash
kubectl --context <mesh-ctx> -n istio-system delete secret istio-remote-secret-<removed-member>
```

`deletionPolicy: Delete` is not used: the remote-secret PushSecrets select every
member's SecretStore by label, so ESO would keep its finalizer on a removed member's
SecretStore and the store would never finish deleting.
