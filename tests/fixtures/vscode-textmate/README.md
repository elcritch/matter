# vscode-textmate fixture attribution

This directory contains test data imported from
[`microsoft/vscode-textmate`](https://github.com/microsoft/vscode-textmate) at
commit `fbe49961ab8077e587fdf5282019655ae69e5f9e`.

`while/whileLang.plist` was imported from
`test-cases/suite1/fixtures/whileLang.plist`. Its MIT license is copied in
[`LICENSE.md`](LICENSE.md).

The corresponding ports are the nine entries of
`test-cases/suite1/whileTests.json`, implemented in
`tests/tupstreamwhile.nim`:

1. While should match begin and stop on next line if while condition fails
2. While should match multiple lines while condition holds
3. While condition can match anywhere in line
4. Begin of while should consume entire rest of line.
5. Nested whiles should match using only inner most while on a mached line
6. Nested whiles should check line for outer most while to inner most while
7. Nested whiles should move line ahead before checking other conditions
8. Nested whiles should check line for outer most while to inner most while
9. Should Correctly handle anchor in while rule
