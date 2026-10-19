"""Durable, run-scoped copies of the exact terminal events sent to Telos."""
import uuid
from pathlib import Path


class TurnCheckpoint:
    def __init__(self, path, run_id, write_json):
        self.path = Path(path)
        self.run_id = str(uuid.UUID(run_id)) if run_id is not None else None
        self.write_json = write_json
        self.phone_may_have_acted = False
        self.turn_exit_reason = None
        self.recorded = False

    def record(self, kind, values):
        """Persist before emission; a late pipe error cannot replace a saved result."""
        if self.recorded:
            return
        if kind not in ('done', 'error'):
            raise ValueError('Only terminal worker events can be checkpointed.')
        if not isinstance(values.get('text'), str):
            raise ValueError('A terminal event requires text.')
        if kind == 'done' and (values.get('status') not in ('ready', 'needs_input')
                               or not isinstance(values.get('summary'), str)):
            raise ValueError('A done event requires its exact final status and summary.')
        event = {'type': kind, **values}
        payload = {'event': event,
                   'status': values['status'] if kind == 'done' else 'error',
                   'phone_may_have_acted': self.phone_may_have_acted}
        if self.run_id is not None:
            payload['run_id'] = self.run_id
        if self.turn_exit_reason:
            payload['turn_exit_reason'] = self.turn_exit_reason
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.write_json(self.path, payload)
        self.recorded = True
