# Web API baseline

`public.d.ts` snapshots every emitted declaration in the npm package. It makes public
TypeScript contract changes reviewable and blocks accidental drift after 1.0.

Run `Scripts/check_web_public_api.sh` to verify it. Use `--update` only after reviewing a
deliberate compatibility change.
