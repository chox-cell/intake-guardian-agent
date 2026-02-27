import { test } from 'node:test';
import assert from 'node:assert';
import { mountUi } from './routes.js';

test('Vulnerability Reproduction: XSS via Base URL', async (t) => {
  const handlers: any[] = [];
  const app = {
    get: (path: string, ...args: any[]) => {
      const handler = args[args.length - 1];
      handlers.push({ method: 'GET', path, handler });
    },
    post: (path: string, ...args: any[]) => {
       const handler = args[args.length - 1];
       handlers.push({ method: 'POST', path, handler });
    }
  } as any;

  mountUi(app);

  // Find the /ui/pilot route
  const route = handlers.find(h => h.path === '/ui/pilot');
  assert.ok(route, 'Route /ui/pilot not found');

  // Mock Request with malicious headers
  const req = {
    headers: {
      'x-forwarded-proto': 'javascript',
      'x-forwarded-host': 'alert(1)//'
    },
    socket: {},
    query: {},
    // Mock authentication middleware result which is expected by the handler
    auth: { tenantId: 't1', k: 'k1' }
  } as any;

  let responseBody = '';
  const res = {
    setHeader: () => {},
    end: (body: string) => { responseBody = body; }
  } as any;

  await route.handler(req, res);

  // Check for XSS
  // We expect to find href="javascript://alert(1)//..." if the vulnerability exists
  const xssPattern = /href="javascript:\/\/alert\(1\)\/\//;

  assert.doesNotMatch(responseBody, xssPattern, 'Should NOT contain XSS payload in href');

  // Also verify that the output is sanitized as expected
  // The fix converts javascript: to http: and sanitizes the host
  // host 'alert(1)//' -> 'alert1' (parentheses and slashes removed by regex)
  // proto 'javascript' -> 'http'
  const expectedSanitized = 'http://alert1';
  assert.match(responseBody, new RegExp(expectedSanitized), 'Should contain sanitized URL');
});
