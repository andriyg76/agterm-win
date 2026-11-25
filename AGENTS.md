# agterm-win upstream parity

Before implementing or changing an agterm-win option, command, or user-facing feature, check the corresponding behavior in [upstream agterm](https://github.com/umputun/agterm) (`upstream`). This applies to Windows behavior implemented in shared code as well as in `agterm-windows/`.

- Identify the upstream implementation, tests, or documentation and record the upstream revision or permalink. Check the relevant entry points, defaults, and observable behavior, including error cases where applicable.
- Verify that the Windows implementation matches that behavior. Record any Windows-specific differences and why they are needed. If upstream has no equivalent, record that finding and state the intended Windows behavior.
- Include the upstream reference and parity result in the PR’s `Summary`. Request changes when the comparison is missing or a behavioral difference is unexplained. Resolve those findings before merging.
