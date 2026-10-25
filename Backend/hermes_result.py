"""Translate Hermes turn boundaries into factual Telos task results.

Hermes can stop with ``completed=False`` and useful history but no ``error``
(notably max_iterations_reached). A model's partial summary is not completion
evidence. Preserve its transcript before reporting the incomplete boundary.
"""
import re


PHONE_RESUME_INSTRUCTIONS = (
    ' PHONE RESUME: The previous turn stopped after phone operations may have run. '
    'Its saved tool history is the execution record, not an instruction to replay it. '
    'First inspect the current phone state and verify whether the requested message '
    'or other final action already happened. Never repeat a send, purchase, deletion '
    'or submission merely because the prior turn stopped. If its real outcome '
    'cannot be verified, ask the user to check it before any repeat commit. '
)


def _safe_detail(value):
    if not isinstance(value, str):
        return ''
    value = re.sub(r'sk-[A-Za-z0-9_-]+', '[redacted]', value)
    value = re.sub(r'(?i)(bearer\s+)\S+', r'\1[redacted]', value)
    value = re.sub(r'(?i)((?:api[_-]?key|token|secret|password)\s*[=:]\s*)[^\s,;]+',
                   r'\1[redacted]', value)
    value = re.sub(r'(https?://)[^/\s@]+@', r'\1[redacted]@', value)
    return ' '.join(value.split())[:240]


def _current_turn_phone_calls(result):
    messages = result.get('messages')
    if not isinstance(messages, list):
        return False
    start = result.get('current_turn_user_idx')
    if not isinstance(start, int) or isinstance(start, bool) or not 0 <= start < len(messages):
        start = next((i for i in range(len(messages) - 1, -1, -1)
                      if isinstance(messages[i], dict) and messages[i].get('role') == 'user'), 0)
    for message in messages[start:]:
        if not isinstance(message, dict) or message.get('role') != 'assistant':
            continue
        for call in message.get('tool_calls') or []:
            if (isinstance(call, dict) and isinstance(call.get('function'), dict)
                    and call['function'].get('name') == 'phone_exec'):
                return True
    return False


def turn_boundary(result, *, phone_used=False):
    """Return an incomplete, needs-input result, or None for a genuine final.

Never copy partial ``final_response`` into a completion notice: it can be a
budget summary or an optimistic model claim after a partially executed tool.
"""
    if not isinstance(result, dict):
        result = {'turn_exit_reason': 'invalid_result'}
    reason = str(result.get('turn_exit_reason') or '')
    final = result.get('final_response')
    if (result.get('completed') is True and not result.get('error')
            and not any(result.get(key) for key in ('failed', 'partial', 'interrupted'))
            and reason != 'guardrail_halt' and isinstance(final, str) and final.strip()):
        return None

    limit = re.fullmatch(r'max_iterations_reached\((\d{1,6})/(\d{1,6})\)', reason)
    failure = str(result.get('failure_reason') or '')
    if reason == 'invalid_result':
        notice = '执行引擎没有返回有效结果，任务尚未完成。'
    elif limit:
        notice = f'这件事步骤比较多，已经做了 {int(limit[1])} 步，还没完成。进度已保存，回复「继续」我接着做。'
    elif reason == 'budget_exhausted':
        notice = '这件事用时较长，本次执行时间已用完，还没完成。进度已保存，回复「继续」我接着做。'
    elif result.get('interrupted') or reason.startswith('interrupted'):
        notice = '任务已中断，尚未完成。'
    elif reason == 'guardrail_halt':
        notice = '执行保护已暂停本次操作，任务尚未完成。'
    elif failure == 'context_overflow' or reason.startswith(('context_compression', 'compaction_')):
        notice = '会话内容超过模型可处理范围，本次操作已暂停，任务尚未完成。'
    elif failure == 'session_busy':
        notice = '另一个执行过程仍占用此任务，本次请求尚未处理。'
    elif reason.startswith('local_processing_error'):
        notice = '执行中的消息处理出现异常，任务尚未完成。'
    elif failure == 'loop_error' or reason.startswith(('repeated_outer_errors', 'pending_tool_result')):
        notice = '执行流程出现异常，任务尚未完成。'
    elif failure == 'empty_response':
        notice = '模型未返回完整回复，任务尚未完成。'
    elif result.get('error'):
        detail = _safe_detail(result['error'])
        notice = f'任务未完成：{detail}' if detail else '执行引擎报告异常，任务尚未完成。'
    elif result.get('partial'):
        notice = '本次只完成了部分操作，任务尚未完成。'
    elif not isinstance(final, str) or not final.strip():
        notice = '模型没有返回完整结果，任务尚未完成。'
    else:
        notice = '本次执行提前停止，任务尚未完成。'
    phone_may_have_acted = bool(phone_used or _current_turn_phone_calls(result))
    if phone_may_have_acted:
        notice += ('\n\n部分手机操作可能已经执行。请先核对手机当前页面和实际发送状态，'
                   '再决定是否继续，避免重复发送。')
    return {'text': notice, 'summary': notice, 'status': 'needs_input',
            'phone_may_have_acted': phone_may_have_acted,
            'turn_exit_reason': _safe_detail(reason) or 'incomplete_result'}


def preserve_turn(result, history_file, write_json, *, phone_used=False):
    """Persist the exact returned message list before inspecting completion flags."""
    if isinstance(result, dict) and isinstance(result.get('messages'), list):
        write_json(history_file, result['messages'])
    return turn_boundary(result, phone_used=phone_used)
