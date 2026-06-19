"""Shared bank configuration.

Applied to the team-wide shared bank. All team members can read/write.
"""

CONFIG = {
    "name": "Team Shared Memory",
    "retain_mission": (
        "Extract team decisions, architectural standards, operational runbooks, "
        "shared tooling patterns, and cross-project knowledge. Ignore individual "
        "preferences and personal context."
    ),
    "reflect_mission": (
        "You are a team knowledge base. Reference team standards and past "
        "decisions. Be factual and cite specific prior decisions when possible."
    ),
    "observations_mission": (
        "Identify team-wide patterns, recurring decisions, evolving standards, "
        "and areas where team practices have shifted over time."
    ),
    "disposition_skepticism": 4,
    "disposition_literalism": 5,
    "disposition_empathy": 1,
    "retain_extraction_mode": "concise",
    "enable_observations": True,
    "entity_labels": [
        {
            "key": "project",
            "description": "Project or repository the decision applies to",
            "type": "text",
            "optional": True,
            "tag": True,
        },
        {
            "key": "decision_type",
            "description": "Type of team decision",
            "type": "multi-values",
            "optional": True,
            "tag": True,
            "values": [
                {"value": "architecture", "description": "Architectural decisions and patterns"},
                {"value": "tooling", "description": "Shared tooling and infrastructure choices"},
                {"value": "process", "description": "Team processes and workflows"},
                {"value": "standard", "description": "Coding standards and conventions"},
                {"value": "runbook", "description": "Operational procedures and runbooks"},
            ],
        },
    ],
}

DIRECTIVES = [
    {
        "name": "No secrets",
        "content": "Never store or surface credentials, API keys, or secrets.",
        "priority": 10,
    },
    {
        "name": "Decision provenance",
        "content": "Reference the source of decisions (who decided, when, in what context).",
        "priority": 8,
    },
]

MENTAL_MODELS = [
    {
        "name": "Team Standards",
        "source_query": "What are the team's agreed engineering standards and conventions?",
    },
    {
        "name": "Architecture Decisions",
        "source_query": "What architectural decisions has the team made and why?",
    },
]
