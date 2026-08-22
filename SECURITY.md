# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| < latest | :x:               |

## Reporting a Vulnerability

Report security vulnerabilities **privately** using GitHub Security Advisories
("Report a vulnerability" under the Security tab), not public issues. Private
reporting keeps disclosure coordinated so a fix can land before details are
public.

For findings that fit a known weakness class, classify under the Common Weakness
Enumeration (CWE) where possible, and include the affected version
(`yuxi --version`) and a minimal reproduction.

The autonomous engine accepts semi-trusted task text and compiles + runs
generated native code; treat any path that lets generated code reach the host
filesystem, network, or process boundary outside its workdir as a high-severity
finding.
