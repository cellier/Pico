"""Product-oriented Zoom routing; capability metadata is never execution evidence.

This guide only reads local connection state and current tool catalogs. It does
not invoke any product operation, change credentials, or drive the Zoom UI.
"""
import copy
import re

from zoom_connector import ZoomError


def _operation(summary, *tools, **extra):
    return {'summary': summary, 'candidate_tools': list(tools), **extra}


_PRODUCTS = {
    'calendar': {
        'name': 'Zoom Calendar', 'aliases': ['calendar', '日历', '日程', 'calendar events'],
        'services': ['calendar'],
        'operations': {
            'read': _operation('Resolve the in-use calendar and read exact events or availability.', 'calendar_get_inuse', 'calendar_list', 'calendar_list_events', 'calendar_get_event', 'calendar_query_freebusy'),
            'create': _operation('Create an event with its exact calendar, timezone, attendees and recurrence.', 'calendar_insert_event'),
            'edit': _operation('Read the current event first, then patch only requested fields and the correct recurrence instance.', 'calendar_patch_event'),
            'delete': _operation('Delete only the requested event or recurrence instance after resolving its exact identity.', 'calendar_delete_event'),
            'share': _operation('Inspect the existing calendar/event sharing UI; do not invent a calendar-sharing API.'),
            'import': _operation('Use the signed-in calendar UI for supported calendar-file import.'),
            'export': _operation('Use the signed-in calendar UI for supported export; reading events alone is not an exported calendar file.'),
            'advanced': _operation('Use current schemas for recurrence, free/busy, attendees, reminders and calendar binding; use UI for remaining settings.', 'calendar_query_freebusy', 'calendar_insert_event', 'calendar_patch_event'),
        },
    },
    'chat': {
        'name': 'Zoom Team Chat', 'aliases': ['chat', 'team chat', 'team_chat', '聊天', '群聊', '消息', '频道'],
        'services': ['team_chat', 'contact'],
        'operations': {
            'read': _operation('Search exact contacts, channels, messages and threads; distinguish failed collection from no results.', 'team_chat_contact_search', 'team_chat_channel_search', 'team_chat_msg_search', 'team_chat_msg_get_by_id', 'team_chat_msg_replies_fetch'),
            'create': _operation('Send original text, reply or schedule a message to a resolved recipient; create channels when requested.', 'team_chat_msg_send', 'team_chat_channel_create'),
            'edit': _operation('Edit the exact permitted message or channel, preserving unrelated settings.', 'team_chat_msg_update', 'team_chat_channel_update'),
            'delete': _operation('Delete the exact requested message or change channel membership only with current authorization.', 'team_chat_msg_delete', 'team_chat_channel_members_remove'),
            'share': _operation('Use Pico’s registered zoom_upload_files for attachments; resolve the recipient first. File transfer may require separate Zoom OAuth.', 'team_chat_msg_send', local_helpers=['zoom_upload_files']),
            'import': _operation('Upload only requested local files with Pico’s registered zoom_upload_files, confined to the task workspace; never read arbitrary file paths.', local_helpers=['zoom_upload_files']),
            'export': _operation('Read selected history and use Pico’s registered zoom_download_files for explicitly requested attachment IDs.', 'team_chat_msg_fetch', local_helpers=['zoom_download_files']),
            'advanced': _operation('Discover current channel/member, reminder, bookmark, pin, reaction, mention-group and scheduled-message tools; each uses its exact schema.'),
        },
    },
    'meeting': {
        'name': 'Zoom Meetings', 'aliases': ['meeting', 'meetings', '会议', '开会'],
        'services': ['meeting'],
        'operations': {
            'read': _operation('Find the exact meeting and inspect details, invitees, assets, transcripts or summaries.', 'meeting_search', 'meeting_detail_get', 'meeting_invitees_list', 'meeting_assets_get', 'meeting_transcript_get', 'meeting_summary_get'),
            'create': _operation('Schedule a new meeting using the requested time, duration and settings.', 'meeting_create'),
            'edit': _operation('Read the meeting first, then update requested basic settings, features, invitees or roles.', 'meeting_basic_update', 'meeting_feature_update', 'meeting_invitees_update', 'meeting_roles_update', 'meeting_alternative_hosts_update'),
            'delete': _operation('Delete only the requested meeting or summary; preserve recurrence scope.', 'meeting_delete', 'meeting_summary_delete'),
            'share': _operation('Read the invitation or share a summary using exact requested recipients and settings.', 'meeting_invitation_get', 'meeting_summary_share'),
            'import': _operation('Use signed-in UI for supported meeting-material or other import workflows.'),
            'export': _operation('Read meeting assets and use the signed-in UI or registered bounded download tools to save requested files.', 'meeting_assets_get'),
            'advanced': _operation('Use meeting APIs for schedule/settings management. Joining, leaving, live audio, screen sharing and live meeting controls use Pico’s existing Mac meeting controls and current UI, with separate verification.'),
        },
    },
    'docs': {
        'name': 'Zoom Docs', 'aliases': ['docs', 'doc', 'document', 'documents', 'canvas', '文档', '文書', '画布'],
        'services': ['docs', 'docs_data_table'],
        'operations': {
            'read': _operation('Search files, resolve the exact ID, and read Markdown for summarization or fresh XML before editing.', 'docs_file_search', 'docs_file_get_content', 'docs_file_list_children'),
            'create': _operation('Create a native Zoom Doc from Markdown, or create folders/data-table files with their exact supported file_type.', 'docs_file_create_with_content', 'canvas_create_file'),
            'edit': _operation('Require fresh XML and can_edit=true. Insert/update/replace precise blocks, preserve unknown blocks, and rename only when requested.', 'docs_file_insert_blocks', 'docs_file_update_block', 'docs_file_replace_range_of_blocks', 'docs_file_modify_metadata'),
            'delete': _operation('Delete the exact requested block or file, preserving unrelated content.', 'docs_file_delete_block', 'docs_file_delete'),
            'share': _operation('Inspect current access policy and collaborators, then apply only requested access/role/ownership changes.', 'docs_file_get_general_access_policy', 'docs_file_list_collaborators', 'docs_file_add_collaborators', 'docs_file_modify_collaborators', 'docs_file_remove_collaborator', 'docs_file_modify_general_access_policy', 'docs_file_transfer_ownership'),
            'import': _operation('For a requested Markdown file already in this task workspace, use Pico read_document then docs_file_create_with_content through zoom_write. Ensure the read contains the complete file; never import a truncated excerpt as the whole document. Use the signed-in Docs UI for other source formats, images, large files or native import workflows.', 'docs_file_create_with_content', pico_tools=['read_document'], execution_steps=['read_document for the requested task-relative Markdown source', 'zoom_schema then zoom_write docs/docs_file_create_with_content with the complete Markdown and requested title/parent', 'Read back the new native Zoom Doc and verify content and target']),
            'export': _operation('For a requested Markdown export, inspect zoom_schema then use docs_file_get_content format=markdown through zoom_read and save the complete returned content with Pico save_document. Read all output chunks before saving. Use signed-in Docs UI for child-page trees, other formats or content the API cannot return completely.', 'docs_file_get_content', pico_tools=['save_document'], execution_steps=['zoom_schema then zoom_read docs/docs_file_get_content format=markdown for the exact requested document', 'Follow returned output pagination to obtain the complete content; do not silently omit embedded tables', 'save_document with a task-relative .md filename and complete content, then report the actual saved artifact']),
            'advanced': _operation('Use precise XML block edits, comments and Docs data-table operations. Fetch required specs silently, then preserve the existing document structure.', 'docs_comment_create', 'canvas_data_table_create', 'docs_data_table_schema', 'docs_data_table_view', 'docs_data_table_chart'),
        },
    },
    'sheets': {
        'name': 'Zoom Sheets', 'aliases': ['sheets', 'sheet', 'spreadsheet', 'spreadsheets', '电子表格', '表格'],
        'services': ['sheets'],
        'operations': {
            'read': _operation('Search spreadsheet files, describe workbook/worksheet structure and read exact cells or table regions.', 'docs_file_search', 'sheets_describe_spreadsheet', 'sheets_describe_worksheet', 'sheets_discover_tables', 'sheets_read_cells'),
            'create': _operation('Create a native Zoom spreadsheet and add worksheets.', 'sheets_create_spreadsheet', 'sheets_add_worksheet'),
            'edit': _operation('Edit values, formulas, cell formats, rows/columns, merges, notes, checkboxes and progress bars with the exact current schema.', 'sheets_edit_cells', 'sheets_update_worksheet'),
            'delete': _operation('Delete requested worksheets, rows/columns, charts, pivot tables or formatting rules. Whole-file deletion requires a separately discovered applicable file API or UI.', 'sheets_delete_worksheet', 'sheets_edit_cells', 'sheets_update_worksheet'),
            'share': _operation('Inspect the native spreadsheet sharing UI. Do not assume Docs permission APIs accept spreadsheets without verifying their documented item support.'),
            'import': _operation('Use the signed-in Sheets UI to import the requested XLSX/CSV or other supported source file; creating cell values is not importing an existing workbook faithfully.'),
            'export': _operation('Use the signed-in Sheets UI for native workbook export/download; cell readback alone is not an exported workbook.'),
            'advanced': _operation('sheets_update_worksheet supports ordered atomic actions: add/update/delete charts, create/update/delete pivot tables, conditional-formatting rules, filter/remove filter, sorting, resize dimensions and view settings. sheets_edit_cells supports formulas and detailed cell features.', 'sheets_update_worksheet', 'sheets_edit_cells', action_names=['addChart', 'updateChart', 'deleteChart', 'createPivotTable', 'updatePivotTable', 'deletePivotTable', 'addConditionalFormattingRule', 'deleteConditionalFormattingRule', 'clearConditionalFormattingRules', 'setFilter', 'removeFilter', 'sortRange', 'resizeDimensions', 'viewSettings']),
        },
    },
    'slides': {
        'name': 'Zoom Slides', 'aliases': ['slides', 'slide', 'presentation', 'presentations', '幻灯片', '演示文稿', '幻灯'],
        'services': ['docs'], 'search_file_type': 'presentation',
        'operations': {
            'read': _operation('Find the native Zoom Slides file by docs_file_search with file_types=[presentation]. Search results are metadata/links; inspect the actual deck in the signed-in UI for its slides and content.', 'docs_file_search', metadata_only=True),
            'create': _operation('Create the actual native Zoom Slides deck in the already signed-in Zoom UI.'),
            'edit': _operation('Open the actual deck in the signed-in UI and edit slide content, layout, images, charts, notes or order; verify the visible result.'),
            'delete': _operation('Delete the requested slide/object/deck through the current Slides UI, preserving all unrelated slides.'),
            'share': _operation('Use the native Slides sharing UI for exact recipients, links, roles or publication settings.'),
            'import': _operation('Import the requested PPTX or other supported source through the actual Slides UI; verify the native deck and slide content.'),
            'export': _operation('Export/download the actual native deck through its UI and verify the saved file and requested format.'),
            'advanced': _operation('Use current Slides UI for themes, presenter notes, presenting, animations, playback and other requested actions; do not invent a Slides API.'),
        },
        'native_product_required': True,
        'prohibited_substitutes': ['A Zoom Doc is not a Zoom Slides deck.', 'A local PPTX/HTML/PDF is not a created or edited native Zoom Slides file.'],
        'api_boundary': 'The audited gateway/local catalogs have no native Slides create/edit/import/export API. canvas_create_file supports only shared_folder, folder, doc and data_table; presentation is a search filter only.',
    },
    'paper': {
        'name': 'Zoom Paper', 'aliases': ['paper', 'papers', 'paper doc', 'paper_doc', '白纸', '分页文档'],
        'services': ['docs'], 'search_file_type': 'paper_doc',
        'product_kind': 'Paged rich-text document, distinct from Zoom Docs/Canvas.',
        'reference_url': 'https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0085665',
        'operations': {
            'read': _operation('Find the native Paper file by docs_file_search with file_types=[paper_doc]. Search returns metadata/links; inspect actual Paper content in its signed-in UI.', 'docs_file_search', metadata_only=True),
            'create': _operation('Create the actual native Zoom Paper file in the already signed-in Zoom UI.'),
            'edit': _operation('Edit the actual Paper paged rich-text document in the current signed-in UI: headings, text/font formatting, paragraph styles, tables and images. Verify the native document result.'),
            'delete': _operation('Delete only requested Paper content or the exact Paper file through its native UI.'),
            'share': _operation('Use native Paper sharing UI for exact recipients, roles and links.'),
            'import': _operation('Use the actual Paper UI for its supported import workflow and verify the native Paper result.'),
            'export': _operation('Use native Paper export/download UI and verify the requested saved format.'),
            'advanced': _operation('Use the current Paper UI for page layout, margins, orientation, page size, headers/footers, page numbers, headings, fonts, table of contents and other native document actions; do not assume Docs XML is Paper content.'),
        },
        'native_product_required': True,
        'prohibited_substitutes': ['A Zoom Doc, local Markdown/PDF or image is not a created or edited native Zoom Paper file.'],
        'api_boundary': 'The audited gateway/local catalogs have no native Paper create/edit/import/export API. paper_doc is a search filter only; canvas_create_file does not accept it.',
    },
    'clips': {
        'name': 'Zoom Clips', 'aliases': ['clips', 'clip', '短视频', '视频片段'],
        'services': ['clips'],
        'operations': {
            'read': _operation('Read clip metadata, transcripts, collaborators, comments and analytics.', 'clip_list', 'clip_get', 'clip_transcript_get', 'clip_collaborator_list', 'clip_comment_list'),
            'create': _operation('For an explicitly requested AI-avatar video, discover avatars and call clip_create with avatar_id and transcript_content. Generation is asynchronous: read actual status/output before claiming completion. Ordinary screen recording or local-video upload uses the Clips UI.', 'avatar_list', 'clip_create'),
            'edit': _operation('Update title/description or trim/restore actual video ranges; inspect current metadata first.', 'clip_update', 'trim_clip', 'edit_restore_trim'),
            'delete': _operation('Soft-delete the exact clip or delete only the requested comment/collaborator.', 'clip_delete', 'clip_comment_delete', 'clip_collaborator_delete'),
            'share': _operation('Inspect sharing permissions and add exact requested collaborators and roles.', 'get_clip_metadata', 'clip_collaborator_list', 'clip_collaborator_create'),
            'import': _operation('Upload an ordinary local video in the already signed-in Clips UI. clip_create generates an avatar video and is not a local upload API.'),
            'export': _operation('Use the signed-in Clips UI for supported video download/export; a clip URL or transcript is not the video file.'),
            'advanced': _operation('Generate/read transcripts, reply to comments, inspect analytics and generate translated avatar videos using current exact schemas.', 'clip_transcript_generate', 'clip_comment_reply', 'clip_analytics_overview_get', 'clip_create'),
        },
    },
    'email': {
        'name': 'Zoom Mail', 'aliases': ['email', 'e-mail', 'mail', 'zmail', '邮件', '邮箱'],
        'services': ['mail'],
        'operations': {
            'read': _operation('Search/read exact emails, threads, labels and requested attachments.', 'mcp_search_threads', 'mcp_get_message', 'zmail_list_emails', 'zmail_get_email', 'mcp_get_attachment', 'zmail_list_labels'),
            'create': _operation('Create a draft or send exact requested mail. For attachments, create/update a draft with Base64 attachment bytes, then send that exact draft; mcp_send_message has no attachment field.', 'zmail_create_draft', 'zmail_update_draft', 'zmail_send_draft', 'mcp_send_message'),
            'edit': _operation('Edit an unsent draft, or change labels/read/star/archive state on an existing message. Sent body content cannot be silently rewritten.', 'zmail_update_draft', 'zmail_modify_email'),
            'delete': _operation('Delete a requested draft or move exact requested email to TRASH via supported labels; permanent mailbox deletion requires native UI if available.', 'zmail_delete_draft', 'zmail_modify_email'),
            'share': _operation('Send/reply/forward only to exact current authorized recipients, preserving CC/BCC and reply headers. Attachments use the draft workflow.', 'mcp_send_message', 'zmail_create_draft', 'zmail_send_draft'),
            'import': _operation('For attachments use the draft workflow. Mailbox or message-file import uses supported native Mail UI.'),
            'export': _operation('Read/download explicitly requested attachments with the matching tool; use native UI for message/mailbox export.', 'mcp_get_attachment'),
            'advanced': _operation('Use current schema for scheduled sends, reply threading, CC/BCC, inline attachments and system labels. Label descriptions do not override the actual schema enum.', 'mcp_send_message', 'zmail_create_draft', 'zmail_update_draft', 'zmail_modify_email'),
        },
    },
    'whiteboard': {
        'name': 'Zoom Whiteboard', 'aliases': ['whiteboard', 'whiteboards', '白板'],
        'services': ['whiteboard'],
        'operations': {
            'read': _operation('Find a whiteboard, read actual pages/content and collaborator state.', 'whiteboard_list', 'whiteboard_get', 'whiteboard_content_get', 'whiteboard_collaborators_get_v2'),
            'create': _operation('Create a native whiteboard or a requested supported diagram/brainstorm/meeting-summary board.', 'whiteboard_create', 'whiteboard_mermaid_script_create', 'whiteboard_strategy_analysis_create', 'whiteboard_meeting_summary_create', 'whiteboard_brainstorming_create'),
            'edit': _operation('Read actual contentObjects and preserve unknown renderer fields, pages and unrelated objects before saving.', 'whiteboard_content_save', 'whiteboard_update'),
            'delete': _operation('Delete exact content or board only when requested; whole whiteboard deletion is permanent.', 'whiteboard_content_delete', 'whiteboard_delete'),
            'share': _operation('Inspect existing collaborators then add/update/remove exact requested access.', 'whiteboard_collaborators_get_v2', 'whiteboard_collaborators_add', 'whiteboard_collaborator_update', 'whiteboard_collaborator_delete'),
            'import': _operation('Use native Whiteboard UI for supported source-file/image import.'),
            'export': _operation('Use native Whiteboard UI for supported export formats; JSON readback is not a visual export.'),
            'advanced': _operation('Use actual renderer objects or supported diagram/analysis generators. Do not invent a complete renderer schema from the free-form contentObjects field.', 'whiteboard_mermaid_script_create', 'whiteboard_content_save'),
        },
    },
}


# Remaining gateway products use the same focused live-discovery mechanism.
for _key, _name, _aliases, _service in (
    ('tasks', 'Zoom Tasks', ['tasks', 'task', '待办', '任务'], 'tasks'),
    ('recording', 'Zoom Recordings', ['recording', 'recordings', '录制', '录音', '录像'], 'recording'),
    ('phone', 'Zoom Phone', ['phone', '电话', '短信'], 'phone'),
    ('webinar', 'Zoom Webinars', ['webinar', 'webinars', '网络研讨会', '研讨会'], 'webinar'),
    ('workspace', 'Zoom Workspace', ['workspace', 'workspaces', '工位', '空间预约', '会议室'], 'workspace'),
    ('accelerator', 'Zoom Revenue Accelerator', ['accelerator', 'revenue accelerator', 'zra', '销售加速器'], 'accelerator'),
    ('contacts', 'Zoom Contacts', ['contacts', 'contact', '联系人', '通讯录'], 'contact'),
    ('data_tables', 'Zoom Docs Data Tables', ['data table', 'data tables', 'data_table', '数据表', '多维表格'], 'docs_data_table'),
):
    _PRODUCTS[_key] = {
        'name': _name, 'aliases': _aliases, 'services': [_service],
        'operations': {action: _operation(
            ('Discover the exact current read/write tools for this product and inspect the schema for the requested action. '
             'Use the matching API first; use the authorized native UI for actions the catalog does not expose. '
             'A missing write API is not proof the signed-in user cannot perform the action in Zoom.'))
            for action in ('read', 'create', 'edit', 'delete', 'share', 'import', 'export', 'advanced')},
    }


_PRODUCTS['tasks']['operations'].update({
    'read': _operation('Read the exact task, assignees, collaborators, comments and ordered steps.', 'tasks_list', 'tasks_get', 'tasks_assignees_get', 'tasks_collaborators_get', 'tasks_comments_get', 'tasks_steps_list'),
    'create': _operation('Create only the requested task or steps, with exact dates, assignees and notification settings.', 'tasks_create', 'tasks_steps_create'),
    'edit': _operation('Update requested task fields/status or exact step; preserve other assignees and work.', 'task_update', 'tasks_step_update', 'tasks_steps_reorder'),
    'delete': _operation('Trash the exact requested task, remove selected steps or delete a selected comment.', 'task_trash', 'tasks_steps_delete', 'tasks_comment_delete'),
    'share': _operation('Inspect existing assignees/collaborators, then add/remove only requested people.', 'tasks_assignee_add', 'tasks_assignee_remove', 'tasks_collaborators_add', 'tasks_collaborators_remove'),
    'advanced': _operation('Manage steps, order, comments, assignees and task completion using exact schemas.', 'tasks_comment_add', 'tasks_steps_reorder', 'task_update'),
})
_PRODUCTS['recording']['operations'].update({
    'read': _operation('Find recordings and read their exact metadata, content and share state.', 'recording_recent_list_search', 'recording_search_my_recordings', 'recording_meta_get', 'recording_content_get', 'recording_share_search'),
    'create': _operation('Start an actual new recording with authorized live meeting/client controls; listing recordings does not start one.'),
    'edit': _operation('Use the native recording editor for requested video edits. Read current recording first; do not assume transcript generation edits the video.', 'recording_meta_get'),
    'delete': _operation('Use the signed-in recording UI for requested recording deletion; no recording-delete API appears in the audited catalog.'),
    'share': _operation('Inspect the existing share settings then update only requested permissions.', 'recording_share_search', 'recording_share_update'),
    'export': _operation('Read exact recording assets and use registered downloads or the native recording UI for actual media export.', 'recording_content_get'),
    'advanced': _operation('Generate a transcript or push the requested recording to Clips using current schemas; verify asynchronous results.', 'recording_transcript_generate', 'recording_clip_push'),
})
_PRODUCTS['phone']['operations'].update({
    'read': _operation('Read requested calls, SMS sessions, voicemail, recordings, transcripts or account phone settings.', 'phone_calllog_search', 'phone_sms_session_search', 'phone_sms_session_message_list', 'phone_voicemail_search', 'phone_get_my_setting'),
    'create': _operation('Use discovered APIs for requested permitted phone-user, call-queue or auto-receptionist setup. Placing calls or sending SMS uses the native Phone UI; do not invent a send-SMS API.', 'phone_create_phone_user', 'phone_create_call_queue', 'phone_create_auto_receptionist'),
    'edit': _operation('Update only authorized phone settings, calling plan, queue membership or number assignment; organization administrator permission remains required where applicable.', 'phone_update_my_setting', 'phone_update_user_calling_plan', 'phone_assign_members_to_call_queue', 'phone_assign_numbers_to_call_queue', 'phone_assign_numbers_to_auto_receptionist'),
    'delete': _operation('Remove the exact authorized phone user with the API, or inspect native UI for other supported removals.', 'phone_remove_phone_user'),
    'advanced': _operation('Use exact current Phone schemas for administration and native UI for live calls/SMS, never treating product access as administrator access.'),
})
_PRODUCTS['webinar']['operations'].update({
    'read': _operation('Search webinars or Zoom Events, then read exact detail, invitations, assets, attendees or transcript.', 'webinar_search', 'webinar_detail_get', 'webinar_invitation_get', 'webinar_assets_get', 'webinar_transcript_get', 'zoomevents_events_search', 'zoomevents_attendees_search'),
    'create': _operation('Use the signed-in native Webinar/Events UI for new webinars or events; the audited catalog has no create operation.'),
    'edit': _operation('Update exact panelists/roles through current APIs, and use native UI for remaining webinar settings.', 'webinar_panelist_update', 'webinar_roles_update'),
    'delete': _operation('Remove requested panelists or use the exact trashcan action schema when applicable. Inspect native UI for whole active webinar deletion.', 'webinar_panelist_remove', 'webinar_trashcan_action'),
    'share': _operation('Read invitation details, then use native UI or explicitly authorized messaging to share with exact recipients.', 'webinar_invitation_get'),
    'advanced': _operation('Read Events registration/role data using discovered schemas; use actual Webinar/Events UI for uncovered native actions.', 'zoomevents_events_get', 'zoomevents_roles_search'),
})
_PRODUCTS['workspace']['operations'].update({
    'read': _operation('Find authorized workspaces, locations, assets, reservations and current settings.', 'workspace_search', 'workspace_list', 'workspace_reservation_list', 'workspace_accessible_location_list', 'workspace_assets_list'),
    'create': _operation('Create the requested workspace reservation, preserving exact resource, time and attendee scope.', 'workspace_reservation_create'),
    'edit': _operation('Update the exact reservation or permitted user/workspace/location/account settings. Administrator restrictions apply.', 'workspace_reservation_update', 'settings_workspace_user_setting_update', 'settings_workspace_setting_update', 'settings_workspace_location_setting_update', 'settings_workspace_account_setting_update'),
    'delete': _operation('Delete only the exact requested reservation.', 'workspace_reservation_delete'),
    'advanced': _operation('Use current resource metadata, reservation constraints and schemas; use signed-in UI for other resource-management actions.', 'workspace_pre_reservation_knowledge_get'),
})
_PRODUCTS['accelerator']['operations'].update({
    'read': _operation('Search authorized conversations, deals, customer accounts/contacts and analyses.', 'search_conversations', 'get_conversation_transcript', 'get_conversation_analysis', 'search_deals', 'get_deal_detail'),
    'advanced': _operation('Read indicators, scorecards and deal activity through current schemas. The audited API catalog contains reads only; requested native changes require inspecting authorized Accelerator UI.', 'search_indicators', 'get_scorecard_sessions', 'get_deal_activities'),
})
_PRODUCTS['contacts']['operations'].update({
    'read': _operation('Resolve exact contacts or inspect permitted groups and organizational structure.', 'contacts_search', 'contacts_group_query', 'contacts_orgchart_query'),
    'create': _operation('Use Team Chat’s discovered contact-add operation when it matches the requested contact action; otherwise inspect native Contacts UI.'),
    'edit': _operation('Inspect authorized Contacts UI for requested contact/profile changes; contact lookup permission is not permission to alter another person’s profile.'),
    'delete': _operation('Use authorized native Contacts UI for requested contact removal; no delete operation appears in the contact API catalog.'),
})
_PRODUCTS['data_tables']['operations'].update({
    'read': _operation('Resolve the table file and read exact schema/views/rows through the argument-sensitive read contract.', 'docs_data_table_fetch', 'docs_file_metadata_tool'),
    'create': _operation('Create a requested native data-table file/table using the required fetched schema specification.', 'docs_data_table_create'),
    'edit': _operation('Apply exact requested column/row/view/chart changes using their required specifications and fresh table identity.', 'docs_data_table_schema', 'docs_data_table_row', 'docs_data_table_view', 'docs_data_table_chart'),
    'delete': _operation('Use the exact discovered row/schema/view/chart operation for requested removal; inspect native UI for whole-file deletion.', 'docs_data_table_row', 'docs_data_table_schema', 'docs_data_table_view', 'docs_data_table_chart'),
    'share': _operation('Inspect native data-table sharing UI and exact existing roles before requested changes.'),
    'advanced': _operation('Use current specifications for formulas, filtered views, charts and row querying; a read wrapper must not execute mutating DDL/DML.', 'docs_data_table_schema', 'docs_data_table_view', 'docs_data_table_chart', 'docs_data_table_fetch'),
})


_INTENTS = {
    'read': ['read', 'search', 'find', 'list', '查看', '读取', '搜索', '查找', '浏览', '查询'],
    'create': ['create', 'new', 'send', 'schedule', '新建', '创建', '发送', '建立', '安排'],
    'edit': ['edit', 'update', 'modify', 'change', '修改', '编辑', '更新', '改动'],
    'delete': ['delete', 'remove', 'trash', '删除', '移除', '丢弃'],
    'share': ['share', 'invite', 'collaborator', '分享', '共享', '邀请', '协作者'],
    'import': ['import', 'upload', '导入', '上传'],
    'export': ['export', 'download', '导出', '下载'],
    'advanced': ['advanced', '高级', '图表', '透视表', '条件格式', '筛选', '排序'],
}


def _normalized(value):
    return re.sub(r'[\s_\-]+', '', value.casefold()).removeprefix('zoom')


def _resolve_product(value):
    normalized = _normalized(value)
    for key, product in _PRODUCTS.items():
        if normalized in {_normalized(item) for item in [key, product['name'], *product['aliases']]}:
            return key
    return None


def _resolve_intent(value):
    normalized = _normalized(value)
    for intent, aliases in _INTENTS.items():
        if normalized in {_normalized(alias) for alias in aliases}:
            return intent
    return None


_UI_RULES = {
    'route': 'signed_in_native_or_browser_ui',
    'execution': 'Inspect the current Zoom page/window using Pico’s registered Mac/browser controls, then perform the current user-requested native product action and read back the actual result. This guide itself does not operate the UI.',
    'authorization': 'Use the same user-authorized Zoom account and current request, exact object, recipient and scope. A missing API or API OAuth scope does not alone mean the UI action is forbidden; inspect the user’s existing authorized UI when allowed.',
    'boundaries': [
        'Never bypass login, browser authorization, an administrator restriction or an object’s actual access prohibition.',
        'Never read, copy or inject tokens, cookies, credential files or another connector’s credentials.',
        'Never silently use UI to circumvent the user disabling Zoom access or cancelling/denying an operation.',
        'If login or approval is required, use the visible authorized flow and let the user complete protected credentials.',
        'Inspect actual UI and current labels/roles; do not invent hidden endpoints, fixed coordinates or stale object IDs.',
        'Do not substitute another file/product for the requested native Zoom result. Verify the actual saved product, target, content and permissions.',
        'If a write outcome is uncertain, inspect the current state before any retry; do not create or send a second copy to verify.',
    ],
}


class ZoomProductGuide:
    def __init__(self, zoom):
        self.zoom = zoom

    def _status(self):
        try:
            raw = self.zoom.status()
        except Exception:
            return {'enabled': None, 'state': 'status_unavailable', 'message': 'Current Zoom connection state could not be read.', 'operation_permission_verified': False}
        return {key: raw.get(key) for key in ('enabled', 'state', 'message', 'verified_at', 'verification')} | {
            'operation_permission_verified': False,
            'note': 'Connection state and past verification are not permission or success evidence for the requested object/action.',
        }

    def _catalog(self, service):
        try:
            raw = self.zoom.catalog({'service': service})
            return {'service': service, 'discovery_state': 'catalog_returned',
                    'tool_names': list(raw.get('tools', [])),
                    'read_tools': list(raw.get('read_tools', [])),
                    'write_tools': list(raw.get('write_tools', [])),
                    'operation_permission_verified': False}
        except ZoomError as error:
            return {'service': service, 'discovery_state': getattr(error, 'state', 'discovery_error'),
                    'message': str(error)[:500], 'tool_names': [],
                    'read_tools': [], 'write_tools': [], 'operation_permission_verified': False,
                    'note': 'Discovery or authorization failure is not evidence that the product action does not exist. Do not bypass actual account or object restrictions.'}
        except Exception:
            return {'service': service, 'discovery_state': 'discovery_error',
                    'message': 'The current service catalog could not be read.',
                    'tool_names': [], 'read_tools': [], 'write_tools': [],
                    'operation_permission_verified': False}

    def guide(self, args):
        if not isinstance(args, dict) or set(args) - {'product', 'intent'}:
            raise ZoomError('invalid_argument', 'Use optional product and intent strings only.')
        for key, maximum in (('product', 160), ('intent', 1200)):
            if key in args and (not isinstance(args[key], str) or len(args[key]) > maximum):
                raise ZoomError('invalid_argument', 'Zoom product and intent must be short text strings.')
        product_query = args.get('product', '').strip()
        intent_query = args.get('intent', '').strip()
        status = self._status()
        common = {
            'connection': status,
            'evidence': 'Routing guidance from audited tool contracts plus the current connection/catalog. No product action was executed or verified by this guide.',
            'permission_policy': 'Inspect the exact current schema before each unfamiliar API. Current discovery, declarations and API counts never prove item access or successful execution. A failed permission request is not no-results or proof the entire product is read-only.',
            'ui_route': copy.deepcopy(_UI_RULES),
        }
        if not product_query:
            return {**common, 'mode': 'product_index',
                    'products': [{'id': key, 'name': product['name'], 'aliases': product['aliases'],
                                  'services': product['services'],
                                  'native_ui_needed_for_content_writes': bool(product.get('native_product_required'))}
                                 for key, product in _PRODUCTS.items()],
                    'next_step': 'Call zoom_product_guide with the user’s product name and optional requested action. Product queries return current service tool names; the index does not crawl every service.'}
        key = _resolve_product(product_query)
        if key is None:
            return {**common, 'mode': 'native_ui_lookup', 'requested_product': product_query,
                    'requested_intent': intent_query,
                    'next_step': 'Resolve the actual named Zoom product and requested action in the user’s existing authorized Zoom UI. An unrecognized product/action name in this guide is not an unsupported-action verdict. Do not guess an API or substitute a different product.'}
        product = copy.deepcopy(_PRODUCTS[key])
        catalogs = [self._catalog(service) for service in product['services']]
        live_tools = {tool for catalog in catalogs for tool in catalog['tool_names']}
        for action, operation in product['operations'].items():
            operation['currently_discovered_tools'] = [tool for tool in operation['candidate_tools'] if tool in live_tools]
            operation['route'] = 'api_then_native_ui' if operation['currently_discovered_tools'] else 'native_ui_or_current_catalog'
            operation['next_step'] = ('Inspect zoom_schema for the exact relevant discovered API, then use zoom_read or zoom_write according to its classification. Use UI for uncovered parts.'
                                      if operation['currently_discovered_tools'] else
                                      'Inspect the current service catalogs and use an applicable API only after its schema is known. For remaining or more specific actions, inspect the authorized native Zoom UI; do not declare the action impossible solely from this guide.')
            if product.get('native_product_required') and action != 'read':
                operation['route'] = 'signed_in_native_or_browser_ui'
                operation['next_step'] = 'Perform this action in the actual requested native Zoom product using current authorized UI controls, then verify its saved result. Do not create a Docs/PPTX/PDF substitute.'
        intent = _resolve_intent(intent_query) if intent_query else None
        result = {**common, 'mode': 'product_guide', 'product_id': key,
                  'product': product, 'current_catalogs': catalogs,
                  'requested_intent': intent_query, 'matched_intent': intent}
        if product.get('search_file_type'):
            result['file_discovery'] = {'service': 'docs', 'tool': 'docs_file_search',
                                        'arguments_hint': {'file_types': [product['search_file_type']]},
                                        'metadata_only': True,
                                        'next_step': 'Inspect zoom_schema first, add the user’s focused title query, and use the returned actual file link/ID. The file-type filter is not a create/edit API.'}
        if intent:
            result['recommended_operation'] = copy.deepcopy(product['operations'][intent])
        elif intent_query:
            result['recommended_operation'] = {'route': ('signed_in_native_or_browser_ui' if product.get('native_product_required') else 'api_then_native_ui'),
                                               'summary': 'This more specific action may be supported by a current schema or the actual Zoom UI. Inspect the relevant catalog and authorized product UI; do not report unsupported from an intent keyword mismatch.'}
        return result


def register_zoom_products(register, string, zoom):
    """Register one read-only routing tool; return its guide for focused tests."""
    guide = ZoomProductGuide(zoom)
    register('zoom_product_guide',
             'Choose how to perform a user-requested action in the actual Zoom product. Lists products or resolves English/Chinese aliases and returns current API tool names, common create/edit/delete/share/import/export/advanced routes and authorized native UI fallback. Slides/Paper content actions require the actual native UI, never a Docs/PPTX substitute. Metadata is not proof of permissions or successful execution. Does not change Zoom or operate UI.',
             {'product': string('Optional Zoom product name or English/Chinese alias, e.g. 日历, Chat, Meeting, Docs, Sheets, Slides, Paper, Clips, Email. Omit for the product index.'),
              'intent': string('Optional requested action in English/Chinese, such as create, edit, delete, share, import, export, advanced, or the user’s more specific action.')},
             [], guide.guide)
    return guide
