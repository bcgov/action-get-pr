# Get PR Number (Moved)

> [!IMPORTANT]
> **This action has moved to [`bcgov/actions/image-tracker`](https://github.com/bcgov/actions/tree/main/image-tracker).** This repository is retiring and will be archived. Update workflows to the new path, pinned to a [release](https://github.com/bcgov/actions/releases) (not `@main`):
>
> ```yaml
> - uses: bcgov/actions/image-tracker@vX.Y.Z
>   id: vars
>   with:
>     package: backend
> # PR number: ${{ steps.vars.outputs.pr }}
> ```
>
> | Old input | New input |
> | --- | --- |
> | `github_token` | `token` |
> | _(none)_ | `package` (required): the image to resolve; the PR number comes from that image |
>
> `debug` keeps its name, and `outputs.pr` is still available. `image-tracker` also returns immutable image digests, which are safer to deploy than mutable PR tags.
