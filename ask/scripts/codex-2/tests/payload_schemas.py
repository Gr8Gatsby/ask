#!/usr/bin/env python3
"""
Shared payload schema definitions for codex-2 block types.

Derived from RemoteKitModels.swift — defines which fields are required,
which are optional, and what Python types they must have.

Usage:
    from payload_schemas import validate_payload, SCHEMAS
    validate_payload('agent_session', {'session_id': ..., 'project': ...})
"""

SCHEMAS = {
    'agent_session': {
        'required': {'session_id': str, 'project': str},
        'optional': {'cwd': str, 'last_message': str, 'is_working': bool,
                     'current_tool': str, 'current_preview': str,
                     'is_headless': bool, 'tty': str,
                     'tool_history': list,
                     # current_prompt appears in the tile when user_prompt_submit fires
                     'current_prompt': str},
    },
    'confirmation': {
        'required': {'title': str, 'body': str, 'options': list},
        'optional': {'session_id': str, 'urgency': str, 'style': str,
                     'confirm_label': str, 'deny_label': str},
    },
    'alert': {
        'required': {'title': str, 'body': str},
        'optional': {'icon': str, 'urgency': str},
    },
    'tile': {
        'required': {'label': str},
        'optional': {'status_color': str, 'body': str, 'action_required': bool},
    },
    'start_session': {
        'required': {'repos': list},  # list of {name:str, path:str}
        'optional': {},
    },
    'activity_feed': {
        'required': {'session_id': str, 'project': str, 'entries': list},
        'optional': {},
    },
    'info_card': {
        'required': {'title': str, 'pairs': list},  # list of {key:str, value:str}
        'optional': {},
    },
    'quick_reply': {
        'required': {'title': str, 'options': list},
        'optional': {'description': str, 'allow_custom': bool, 'urgency': str},
    },
}


def validate_payload(block_type: str, payload_dict: dict):
    """Validate that payload_dict matches the schema for block_type.

    Raises AssertionError with a descriptive message if:
      - block_type is not in SCHEMAS
      - a required field is missing
      - a required field has the wrong type
    """
    assert block_type in SCHEMAS, (
        f"block_type={block_type!r} is not a known schema; "
        f"known types: {sorted(SCHEMAS.keys())}"
    )
    schema = SCHEMAS[block_type]
    required = schema.get('required', {})
    for key, type_ in required.items():
        assert key in payload_dict, (
            f"block_type={block_type}: missing required field {key!r} (expected {type_.__name__})"
        )
        assert isinstance(payload_dict[key], type_), (
            f"block_type={block_type}: field {key!r} has type "
            f"{type(payload_dict[key]).__name__!r}, expected {type_.__name__!r}; "
            f"value={payload_dict[key]!r}"
        )
