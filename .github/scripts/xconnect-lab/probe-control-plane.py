"""Read-only deployment guard. No cookie, bearer or service credential is sent."""
import json
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def check_response(status, headers, body, *, portal):
    if status != 401:
        raise ValueError('Expected an authentication rejection from the deployed API')
    if portal:
        headers = {key.lower(): value for key, value in headers.items()}
        if headers.get('x-frontend-route') != 'ssr-console':
            raise ValueError('Zero BFF is not routed to the Console Worker')
        if json.loads(body) != {'error': 'unauthenticated'}:
            raise ValueError('Zero BFF is missing from the Console artifact or bypassed')


def probe(url, *, portal):
    # Identify the authorized deployment check explicitly. Cloudflare's
    # browser-integrity rules reject urllib's generic Python user agent.
    # This is not browser impersonation and does not disable any edge policy.
    request = Request(url, headers={'Accept': 'application/json',
                                   'User-Agent': 'XConnect-UAT-Lab/1.0'})
    try:
        response = urlopen(request, timeout=15)
    except HTTPError as error:
        response = error
    with response:
        check_response(response.status, response.headers, response.read(65536), portal=portal)


def main():
    with open(sys.argv[1]) as declaration:
        zero = json.load(declaration)['spec']['zero']
    probe(zero['accounts_api_url'].rstrip('/') + '/api/overlay/v1/admin/overview', portal=False)
    portal_origin = zero['portal_url'].removesuffix('/panel/xconnect-zero').rstrip('/')
    for resource in ('overview', 'networks', 'devices', 'invites'):
        probe(portal_origin + '/api/xconnect-zero/' + resource, portal=True)
    print('PASS: formal Accounts authentication boundary and deployed Console Zero BFF routes.')
    print('Scope: anonymous routing guard only; authenticated owner data and UI still require a signed-in acceptance check.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never dump response bodies, headers, redirects or credential material.
        print(f'Control-plane deployment guard failed ({type(error).__name__}). '
              'Verify /api/xconnect-zero/* routing and Console Worker BFF bundle.', file=sys.stderr)
        sys.exit(1)
