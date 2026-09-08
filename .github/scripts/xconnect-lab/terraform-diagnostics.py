#!/usr/bin/env python3
"""Publish only fixed-vocabulary Terraform failure labels, never raw diagnostics."""
import json
import os
from pathlib import Path
import re
import sys

COMMANDS = {'init', 'validate', 'plan', 'apply', 'destroy', 'output', 'show', 'state'}
OPERATIONS = ('RunInstances', 'ModifyInstanceAttribute', 'DescribeInstanceAttribute',
              'DescribeInstances', 'CreateSecurityGroup', 'AuthorizeSecurityGroupIngress',
              'AuthorizeSecurityGroupEgress', 'DeleteSecurityGroup', 'TerminateInstances')
CODES = ('InvalidParameterCombination', 'InvalidParameterValue', 'InvalidParameter',
         'UnauthorizedOperation', 'AccessDenied', 'AccessDeniedException',
         'InsufficientInstanceCapacity', 'InsufficientFreeAddressesInSubnet',
         'MaxSpotInstanceCountExceeded', 'VcpuLimitExceeded', 'SpotMaxPriceTooLow',
         'RequestLimitExceeded', 'DependencyViolation', 'InvalidAMIID.NotFound',
         'InvalidSubnetID.NotFound', 'InvalidGroup.NotFound', 'Unsupported',
         'ExpiredToken', 'InvalidClientTokenId', 'RequestExpired')
RESOURCES = ('aws_instance.gateway', 'aws_instance.client',
             'aws_security_group.gateway', 'aws_security_group.client')
ATTRIBUTES = ('InstanceInitiatedShutdownBehavior',)
MAX_BYTES = 8 * 1024 * 1024


def labels(text, choices):
    # Return our own constants, not captures from untrusted provider output.
    return ','.join(value for value in choices
                    if re.search(r'(?<![\w.])' + re.escape(value) + r'(?![\w.])', text)) or 'unclassified'


def diagnostic_text(raw):
    """Ignore normal JSON progress/plan output; classify only error diagnostics."""
    records = []
    try:
        records.append(json.loads(raw))  # terraform validate -json
    except (ValueError, RecursionError):
        for line in raw.splitlines():  # terraform apply/plan/destroy -json
            try:
                records.append(json.loads(line))
            except (ValueError, RecursionError):
                continue
    texts = []
    for record in records:
        if not isinstance(record, dict):
            continue
        candidates = record.get('diagnostics', [])
        if not isinstance(candidates, list):
            candidates = []
        if isinstance(record.get('diagnostic'), dict):
            candidates = candidates + [record['diagnostic']]
        for entry in candidates:
            if isinstance(entry, dict) and entry.get('severity') == 'error':
                texts.extend(entry[field] for field in ('summary', 'detail', 'address')
                             if isinstance(entry.get(field), str))
    # Init and provider startup failures may be plain text. They still pass
    # through the same fixed vocabulary; nothing from raw is ever emitted.
    return '\n'.join(texts) if records else raw


def summarize(command, raw, code):
    if command not in COMMANDS or not isinstance(code, int) or not 1 <= code <= 255:
        raise ValueError('Invalid diagnostic invocation')
    text = diagnostic_text(raw)
    return (f'Terraform {command} failed (exit {code}); '
            f'resource={labels(text, RESOURCES)}; '
            f'api={labels(text, OPERATIONS)}; '
            f'code={labels(text, CODES)}; '
            f'attribute={labels(text, ATTRIBUTES)}. '
            'Raw details remain runner-private and are not uploaded.')


def main():
    try:
        command, filename, code = sys.argv[1:]
        with Path(filename).open('rb') as log:
            raw = log.read(MAX_BYTES + 1)
        # Oversized logs are not partially classified: that could omit the
        # actual error and attribute progress messages to it instead.
        raw = raw.decode('utf-8', errors='replace') if len(raw) <= MAX_BYTES else ''
        message = summarize(command, raw, int(code))
    except (OSError, ValueError, RecursionError):
        message = 'Terraform failed; safe diagnostic extraction unavailable. Raw details are not published.'
    print('::error::' + message)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        try:
            with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as summary:
                summary.write('\n### Terraform failure (safe labels only)\n\n' + message + '\n')
        except OSError:
            pass  # Annotation remains available even if the summary cannot be written.


if __name__ == '__main__':
    main()
