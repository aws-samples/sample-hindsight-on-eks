"""Personal bank configuration.

Applied per-user. The {alias} placeholder is replaced with the user's alias at runtime.
"""

CONFIG = {
    "name": "{alias}",
    "retain_mission": (
        "Extract technical decisions, architecture choices, debugging findings, "
        "code patterns, AWS/infrastructure configuration, project context, and "
        "user preferences. Ignore greetings, scheduling logistics, and filler."
    ),
    "reflect_mission": (
        "You are a senior developer assistant with deep context on the user's "
        "projects, technical decisions, and preferences. Reference past decisions "
        "when relevant. Be direct and opinionated."
    ),
    "observations_mission": (
        "Identify evolving preferences, recurring patterns, behavioral shifts, and "
        "contradictions with prior knowledge. Focus on durable patterns — not "
        "transient states. Highlight when behavior contradicts previous observations."
    ),
    "disposition_skepticism": 3,
    "disposition_literalism": 4,
    "disposition_empathy": 2,
    "retain_extraction_mode": "concise",
    "enable_observations": True,
    "entity_labels": [
        {
            "key": "project",
            "description": "Project or repository being discussed",
            "type": "text",
            "optional": True,
            "tag": True,
        },
        {
            "key": "scope",
            "description": "Knowledge category: architecture, debugging, tooling, operations, preferences",
            "type": "multi-values",
            "optional": True,
            "tag": True,
            "values": [
                {"value": "architecture", "description": "System design and architectural decisions"},
                {"value": "debugging", "description": "Bug investigations and root causes"},
                {"value": "tooling", "description": "Developer tools, CLI, IDE configuration"},
                {"value": "operations", "description": "Deployment, monitoring, infrastructure operations"},
                {"value": "preferences", "description": "User coding style and workflow preferences"},
            ],
        },
    ],
}

DIRECTIVES = [
    {
        "name": "No secrets",
        "content": "Never store or surface credentials, API keys, or secrets in responses.",
        "priority": 10,
    },
    {
        "name": "Source references",
        "content": "Always reference source file paths when available.",
        "priority": 5,
    },
]

MENTAL_MODELS = [
    {
        "name": "Technical Stack",
        "source_query": "What languages, tools, and frameworks does the user work with?",
    },
    {
        "name": "Current Projects",
        "source_query": "What projects is the user actively working on? What are their statuses?",
    },
    {
        "name": "Coding Preferences",
        "source_query": "What coding patterns and conventions does the user prefer?",
    },
]
