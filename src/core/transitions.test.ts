import { test, describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import { canTransition } from './transitions.js';
import { Status } from '../types/contracts.js';

describe('canTransition', () => {
  const allStatuses: Status[] = ['new', 'triage', 'in_progress', 'waiting', 'resolved', 'closed'];

  const allowedTransitions: Record<Status, Status[]> = {
    new: ['triage', 'in_progress', 'waiting', 'resolved', 'closed'],
    triage: ['in_progress', 'waiting', 'resolved', 'closed'],
    in_progress: ['waiting', 'resolved', 'closed'],
    waiting: ['in_progress', 'resolved', 'closed'],
    resolved: ['closed'],
    closed: []
  };

  it('should allow valid transitions', () => {
    for (const from of allStatuses) {
      const allowed = allowedTransitions[from];
      for (const to of allowed) {
        assert.equal(canTransition(from, to), true, `Transition from ${from} to ${to} should be allowed`);
      }
    }
  });

  it('should disallow invalid transitions', () => {
    for (const from of allStatuses) {
      const allowed = allowedTransitions[from];
      for (const to of allStatuses) {
        if (!allowed.includes(to)) {
          assert.equal(canTransition(from, to), false, `Transition from ${from} to ${to} should be disallowed`);
        }
      }
    }
  });

  it('should disallow self-transitions', () => {
      for (const status of allStatuses) {
          assert.equal(canTransition(status, status), false, `Self-transition for ${status} should be disallowed`);
      }
  });
});
