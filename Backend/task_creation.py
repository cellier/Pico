"""Native task creation: acknowledged persistence, shared stdin serialization."""
import datetime as dt
import json
import re
import uuid


def _evidence_date(text, today):
    """Recognize explicit dates, not vague periods such as 'next week'."""
    dates = set()
    for match in re.finditer(r'(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)', text):
        dates.add(dt.date(*map(int, match.groups())))
    for match in re.finditer(r'(?:(\d{4})年)?(\d{1,2})月(\d{1,2})[日号]?', text):
        year, month, day = match.groups()
        dates.add(dt.date(int(year) if year else today.year, int(month), int(day)))
    months = {name.lower(): index for index, name in enumerate(
        ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'], 1)}
    names = '|'.join(months)
    for match in re.finditer(r'\b(' + names + r')\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b', text, re.I):
        month, day, year = match.groups()
        dates.add(dt.date(int(year) if year else today.year, months[month.lower()], int(day)))
    for match in re.finditer(r'今天|明天|后天|\btoday\b|\btomorrow\b', text, re.I):
        offset = {'今天': 0, '明天': 1, '后天': 2, 'today': 0, 'tomorrow': 1}[match.group().lower()]
        dates.add(today + dt.timedelta(days=offset))
    weekdays = {'一': 0, '二': 1, '三': 2, '四': 3, '五': 4, '六': 5, '日': 6, '天': 6}
    for match in re.finditer(r'(?<![上下本这])([本这下]?)(?:个)?(?:周|星期|礼拜)([一二三四五六日天])', text):
        prefix, name = match.groups()
        offset = weekdays[name] - today.weekday()
        if prefix == '下': offset += 7
        elif not prefix and offset < 0: offset += 7
        dates.add(today + dt.timedelta(days=offset))
    return next(iter(dates)) if len(dates) == 1 else None


def _complete_date_quote(evidence, source):
    weekdays = list(re.finditer(r'[上下本这]*(?:个)?(?:周|星期|礼拜)[一二三四五六日天]', source))
    for quote in re.finditer(re.escape(evidence), source):
        if all(not (day.start() < quote.end() and day.end() > quote.start())
               or (quote.start() <= day.start() and quote.end() >= day.end()) for day in weekdays):
            return True
    return False


def _user_date_text(value):
    if not isinstance(value, str):
        return None
    # The native attachment prompt adds transport metadata after the user's text.
    marker = '\n\nUser attached files, in order of inline attachment markers (paths relative to conversation workspace): '
    text, separator, tail = value.partition(marker)
    if separator:
        try:
            files = json.loads(tail.partition('\n')[0])
            for item in files:
                text = text.replace('[Attachment: ' + item['name'] + ']', '')
        except (ValueError, KeyError, TypeError):
            return None
    return text


def _due_date(task, source, now):
    value = task.get('due_date')
    if value is None:
        return None
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValueError('due_date must be a real YYYY-MM-DD date, or omitted when no exact date was requested.')
    try:
        date = dt.date.fromisoformat(value)
    except ValueError:
        raise ValueError('due_date must be a real YYYY-MM-DD date.') from None
    evidence = task.get('due_date_evidence')
    if not isinstance(evidence, str) or not evidence.strip() or len(evidence) > 160 or not isinstance(source, str) or not _complete_date_quote(evidence, source):
        raise ValueError('due_date_evidence must quote the complete exact date phrase from this current user message, including 下/本/这 weekday qualifiers.')
    try:
        expected = _evidence_date(evidence, now.date())
    except ValueError:
        expected = None
    if expected is None or expected != date:
        raise ValueError('The date does not match its current-user evidence and current Mac date. Use one explicit date, today/tomorrow, or a Chinese weekday. Omit due_date for vague periods such as next week; do not guess a day.')
    return date.isoformat()


def register_task_creation(register, emit, gate, source_validator=None, source_text=None, clock=None):
    clock = clock or (lambda: dt.datetime.now().astimezone())
    local = clock()
    date_context = 'Current Mac date: ' + local.date().isoformat() + ' (' + local.strftime('%A, %Z, UTC%z') + '). '
    def create(args):
        source = args.get('source_message_id')
        if source_validator is not None:
            source = source_validator(source)
        elif source is not None:
            source = str(uuid.UUID(source))
        tasks = args.get('tasks')
        if not isinstance(tasks, list) or not 1 <= len(tasks) <= 5:
            raise ValueError('Provide 1–5 tasks. At most 5 tasks may be created per user request.')
        normalized = []
        current_text = _user_date_text(source_text(source)) if source_text is not None else None
        for task in tasks:
            if not isinstance(task, dict) or any(not isinstance(task.get(k), str) or not task[k].strip() for k in ('title', 'instructions')):
                raise ValueError('Each task needs a short title and self-contained instructions.')
            due = _due_date(task, current_text, clock())
            item = {key: value for key, value in task.items() if key not in ('due_date', 'due_date_evidence')}
            if due is not None:
                item['due_date'] = due
            normalized.append(item)
        request_id = str(uuid.uuid4())
        with gate.lock:
            extra = {'source_message_id': source} if source is not None else {}
            emit('create_tasks', request_id=request_id, tasks=normalized, **extra)
            reply = gate.read_reply(30, request_id=request_id) if hasattr(gate, 'read_reply') else gate.reader(30)
            if not reply or reply.get('request_id') != request_id:
                return {'error': 'Creation acknowledgement unavailable. Do not claim success; check the task list before retrying.'}
            return reply
    register('create_tasks', 'Create tasks in the Pico Task Todo list ONLY when the user explicitly asks. Maximum 5 total per user request, including retries and multiple calls. Tasks are saved, not automatically executed. Return only confirmed results. Do not create tasks just because source documents suggest them. ' + date_context + 'Save an optional due_date only when the current user supplied an exact deadline; quote its original phrase as due_date_evidence. Resolve relative days and weekdays from the current Mac date, not old conversation dates; use get_current_time if the session crosses midnight. Never choose a day for vague periods such as next week or 下周, and never invent a deadline for an undated task.',
             {'source_message_id': {'type': 'string', 'description': 'In continuous Chat, REQUIRED: UUID of the current user message explicitly requesting these saved tasks. Never borrow an older message or invent a UUID.'}, 'tasks': {'type': 'array', 'minItems': 1, 'maxItems': 5, 'items': {'type': 'object', 'properties': {'title': {'type': 'string', 'description': 'Short natural task title in the language appropriate to the current user request and task context. For mixed-language requests preserve the main language and normal product names or technical terms. Preserve an explicitly supplied title and its language.'}, 'instructions': {'type': 'string', 'description': 'Self-contained task context and requested outcome in user language; include relevant source/evidence, not private credentials'}, 'due_date': {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$', 'description': 'Optional exact date in YYYY-MM-DD, for date-based reminders. ' + date_context + 'Only set when explicitly requested for this task in the current user message. Today/tomorrow and Chinese weekdays such as 周四前 or 下周四 are supported. A vague 下周/next week is not an exact due date: omit this field.'}, 'due_date_evidence': {'type': 'string', 'maxLength': 160, 'description': 'Required only with due_date: exact original date phrase copied from the current user message, not a paraphrase, proposal, attachment or old history. Include qualifiers such as 下周 in full.'}}, 'required': ['title', 'instructions']}}}, ['tasks'], create)
