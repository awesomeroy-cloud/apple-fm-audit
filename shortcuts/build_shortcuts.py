#!/usr/bin/env python3
"""Build and sign Apple Shortcuts (.shortcut) for apple-fm-audit."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHORTCUTS_DIR = ROOT / "shortcuts"


def _headers_dict() -> dict:
    return {
        "Value": {
            "WFDictionaryFieldValueItems": [
                {
                    "WFItemType": 0,
                    "WFKey": {
                        "Value": {"string": "Content-Type"},
                        "WFSerializationType": "WFTextTokenString",
                    },
                    "WFValue": {
                        "Value": {"string": "application/json"},
                        "WFSerializationType": "WFTextTokenString",
                    },
                }
            ]
        },
        "WFSerializationType": "WFDictionaryFieldValue",
    }


def _json_body(model: str, content_uuid: str, content_name: str, sys_instruction: str | None = None) -> dict:
    msgs: list[dict] = []
    if sys_instruction:
        msgs.append({
            "WFItemType": 1,
            "WFValue": {
                "Value": {
                    "WFDictionaryFieldValueItems": [
                        {
                            "WFItemType": 0,
                            "WFKey": {"Value": {"string": "role"}, "WFSerializationType": "WFTextTokenString"},
                            "WFValue": {"Value": {"string": "system"}, "WFSerializationType": "WFTextTokenString"},
                        },
                        {
                            "WFItemType": 0,
                            "WFKey": {"Value": {"string": "content"}, "WFSerializationType": "WFTextTokenString"},
                            "WFValue": {"Value": {"string": sys_instruction}, "WFSerializationType": "WFTextTokenString"},
                        },
                    ]
                },
                "WFSerializationType": "WFDictionaryFieldValue",
            },
        })

    msgs.append({
        "WFItemType": 1,
        "WFValue": {
            "Value": {
                "WFDictionaryFieldValueItems": [
                    {
                        "WFItemType": 0,
                        "WFKey": {"Value": {"string": "role"}, "WFSerializationType": "WFTextTokenString"},
                        "WFValue": {"Value": {"string": "user"}, "WFSerializationType": "WFTextTokenString"},
                    },
                    {
                        "WFItemType": 0,
                        "WFKey": {"Value": {"string": "content"}, "WFSerializationType": "WFTextTokenString"},
                        "WFValue": {
                            "Value": {
                                "attachmentsByRange": {
                                    "{0, 1}": {
                                        "Type": "ActionOutput",
                                        "OutputUUID": content_uuid,
                                        "OutputName": content_name,
                                    }
                                },
                                "string": "\ufffc",
                            },
                            "WFSerializationType": "WFTextTokenString",
                        },
                    },
                ]
            },
            "WFSerializationType": "WFDictionaryFieldValue",
        },
    })

    return {
        "Value": {
            "WFDictionaryFieldValueItems": [
                {
                    "WFItemType": 0,
                    "WFKey": {"Value": {"string": "model"}, "WFSerializationType": "WFTextTokenString"},
                    "WFValue": {"Value": {"string": model}, "WFSerializationType": "WFTextTokenString"},
                },
                {
                    "WFItemType": 4,
                    "WFKey": {"Value": {"string": "stream"}, "WFSerializationType": "WFTextTokenString"},
                    "WFValue": False,
                },
                {
                    "WFItemType": 2,
                    "WFKey": {"Value": {"string": "messages"}, "WFSerializationType": "WFTextTokenString"},
                    "WFValue": {
                        "Value": msgs,
                        "WFSerializationType": "WFArrayParameterState",
                    },
                },
            ]
        },
        "WFSerializationType": "WFDictionaryFieldValue",
    }


def make_ask_shortcut(model: str = "system", name: str = "AFM 智能问答") -> dict:
    ask_uuid = str(uuid.uuid4()).upper()
    url_uuid = str(uuid.uuid4()).upper()
    dict_uuid = str(uuid.uuid4()).upper()

    actions = [
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.ask",
            "WFWorkflowActionParameters": {
                "UUID": ask_uuid,
                "WFAskActionPrompt": f"请输入您的问题 ({model})：",
                "WFAskActionDefaultAnswer": "",
                "CustomOutputName": "用户输入",
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
            "WFWorkflowActionParameters": {
                "UUID": url_uuid,
                "CustomOutputName": "响应数据",
                "WFURL": "http://127.0.0.1:1977/v1/chat/completions",
                "WFHTTPMethod": "POST",
                "WFHTTPHeaders": _headers_dict(),
                "WFHTTPBodyType": "JSON",
                "WFJSONValues": _json_body(model, ask_uuid, "用户输入"),
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
            "WFWorkflowActionParameters": {
                "UUID": dict_uuid,
                "CustomOutputName": "回复正文",
                "WFDictionaryKey": "choices.1.message.content",
                "WFInput": {
                    "Value": {
                        "Type": "ActionOutput",
                        "OutputUUID": url_uuid,
                        "OutputName": "响应数据",
                    },
                    "WFSerializationType": "WFTextTokenAttachment",
                },
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.setclipboard",
            "WFWorkflowActionParameters": {
                "WFInput": {
                    "Value": {
                        "Type": "ActionOutput",
                        "OutputUUID": dict_uuid,
                        "OutputName": "回复正文",
                    },
                    "WFSerializationType": "WFTextTokenAttachment",
                }
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
            "WFWorkflowActionParameters": {
                "Text": {
                    "Value": {
                        "attachmentsByRange": {
                            "{0, 1}": {
                                "Type": "ActionOutput",
                                "OutputUUID": dict_uuid,
                                "OutputName": "回复正文",
                            }
                        },
                        "string": "\ufffc",
                    },
                    "WFSerializationType": "WFTextTokenString",
                }
            },
        },
    ]

    return {
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 59511,
            "WFWorkflowIconStartColor": 431817727 if model == "system" else 3031607807,
        },
        "WFWorkflowClientVersion": "2607.1",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowActions": actions,
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": ["MenuBar", "QuickActions", "Services", "ActionExtension"],
    }


def make_selection_shortcut() -> dict:
    detect_uuid = str(uuid.uuid4()).upper()
    url_uuid = str(uuid.uuid4()).upper()
    dict_uuid = str(uuid.uuid4()).upper()

    actions = [
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.detect.text",
            "WFWorkflowActionParameters": {
                "UUID": detect_uuid,
                "CustomOutputName": "选中文本",
                "WFInput": {
                    "Value": {"Type": "ExtensionInput"},
                    "WFSerializationType": "WFTextTokenAttachment",
                },
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
            "WFWorkflowActionParameters": {
                "UUID": url_uuid,
                "CustomOutputName": "响应数据",
                "WFURL": "http://127.0.0.1:1977/v1/chat/completions",
                "WFHTTPMethod": "POST",
                "WFHTTPHeaders": _headers_dict(),
                "WFHTTPBodyType": "JSON",
                "WFJSONValues": _json_body(
                    "system",
                    detect_uuid,
                    "选中文本",
                    sys_instruction="请对以下内容进行简明扼要的总结，提炼核心事实与结论：",
                ),
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
            "WFWorkflowActionParameters": {
                "UUID": dict_uuid,
                "CustomOutputName": "总结内容",
                "WFDictionaryKey": "choices.1.message.content",
                "WFInput": {
                    "Value": {
                        "Type": "ActionOutput",
                        "OutputUUID": url_uuid,
                        "OutputName": "响应数据",
                    },
                    "WFSerializationType": "WFTextTokenAttachment",
                },
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.setclipboard",
            "WFWorkflowActionParameters": {
                "WFInput": {
                    "Value": {
                        "Type": "ActionOutput",
                        "OutputUUID": dict_uuid,
                        "OutputName": "总结内容",
                    },
                    "WFSerializationType": "WFTextTokenAttachment",
                }
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
            "WFWorkflowActionParameters": {
                "Text": {
                    "Value": {
                        "attachmentsByRange": {
                            "{0, 1}": {
                                "Type": "ActionOutput",
                                "OutputUUID": dict_uuid,
                                "OutputName": "总结内容",
                            }
                        },
                        "string": "\ufffc",
                    },
                    "WFSerializationType": "WFTextTokenString",
                }
            },
        },
    ]

    return {
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 59744,
            "WFWorkflowIconStartColor": 1440408063,
        },
        "WFWorkflowClientVersion": "2607.1",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowActions": actions,
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": ["QuickActions", "Services", "ActionExtension"],
    }


def make_shell_shortcut() -> dict:
    ask_uuid = str(uuid.uuid4()).upper()
    shell_uuid = str(uuid.uuid4()).upper()
    script_path = str(ROOT / "scripts" / "afm-ask")

    actions = [
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.ask",
            "WFWorkflowActionParameters": {
                "UUID": ask_uuid,
                "WFAskActionPrompt": "请输入您的问题 (Shell 极速版)：",
                "WFAskActionDefaultAnswer": "",
                "CustomOutputName": "用户问题",
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript",
            "WFWorkflowActionParameters": {
                "UUID": shell_uuid,
                "CustomOutputName": "Shell 输出",
                "Script": f'{script_path} "$1"',
                "Input": {
                    "Value": {
                        "Type": "ActionOutput",
                        "OutputUUID": ask_uuid,
                        "OutputName": "用户问题",
                    },
                    "WFSerializationType": "WFTextTokenAttachment",
                },
                "Shell": "/bin/zsh",
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.setclipboard",
            "WFWorkflowActionParameters": {
                "WFInput": {
                    "Value": {
                        "Type": "ActionOutput",
                        "OutputUUID": shell_uuid,
                        "OutputName": "Shell 输出",
                    },
                    "WFSerializationType": "WFTextTokenAttachment",
                }
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
            "WFWorkflowActionParameters": {
                "Text": {
                    "Value": {
                        "attachmentsByRange": {
                            "{0, 1}": {
                                "Type": "ActionOutput",
                                "OutputUUID": shell_uuid,
                                "OutputName": "Shell 输出",
                            }
                        },
                        "string": "\ufffc",
                    },
                    "WFSerializationType": "WFTextTokenString",
                }
            },
        },
    ]

    return {
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowIcon": {
            "WFWorkflowIconGlyphNumber": 59445,
            "WFWorkflowIconStartColor": 4282601983,
        },
        "WFWorkflowClientVersion": "2607.1",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowActions": actions,
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": ["MenuBar", "QuickActions", "Services"],
    }


def sign_shortcut(unsigned_path: Path, signed_path: Path) -> bool:
    try:
        res = subprocess.run(
            [
                "shortcuts",
                "sign",
                "-m",
                "people-who-know-me",
                "-i",
                str(unsigned_path),
                "-o",
                str(signed_path),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode == 0 and signed_path.exists():
            return True
        sys.stderr.write(f"Sign warning: {res.stderr.strip()}\n")
    except Exception as e:
        sys.stderr.write(f"Signing failed ({e}), keeping unsigned file.\n")
    return False


def build_all() -> None:
    SHORTCUTS_DIR.mkdir(parents=True, exist_ok=True)
    targets = [
        ("AFM 智能问答", make_ask_shortcut("system", "AFM 智能问答")),
        ("AFM 私有云问答 (PCC)", make_ask_shortcut("pcc", "AFM 私有云问答 (PCC)")),
        ("AFM 划词总结", make_selection_shortcut()),
        ("AFM 极速问答 (Shell)", make_shell_shortcut()),
    ]

    for name, data in targets:
        unsigned_file = SHORTCUTS_DIR / f"{name}.unsigned.shortcut"
        final_file = SHORTCUTS_DIR / f"{name}.shortcut"
        with open(unsigned_file, "wb") as f:
            plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

        signed = sign_shortcut(unsigned_file, final_file)
        if signed:
            unsigned_file.unlink()
            print(f"Generated and signed: {final_file.name}")
        else:
            unsigned_file.rename(final_file)
            print(f"Generated (unsigned): {final_file.name}")


if __name__ == "__main__":
    build_all()
