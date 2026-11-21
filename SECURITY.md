# Security policy

## Supported versions

No version has been released yet. Once versions are released, only the latest one gets security fixes.

## Reporting a vulnerability

Report it privately through GitHub's [private vulnerability reporting](https://github.com/paxel/dart-avro/security/advisories/new) (the repository's **Security** tab, **Report a vulnerability**). Do not open a public issue, pull request or discussion for it.

Describe what an attacker gains: for example input that makes the decoder or the container file reader allocate beyond its limits, hang, throw something other than an `AvroException`, or return a value that the bytes do not hold.

The report and its fix are discussed in that advisory, which stays private until the fix is published.

## What is already checked

The repository is held to the standard of [paxel/gates](https://github.com/paxel/gates): CodeQL for the workflows, OpenSSF Scorecard, SonarQube Cloud, the OSV gate on the locked dependencies, the alert gate, strict analysis, a coverage ratchet and fuzzing of the decoder.
