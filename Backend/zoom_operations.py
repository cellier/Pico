"""Exact audited DevHelper Zoom catalog, captured 2026-10-24.

Unknown future tools are unavailable until reviewed. Read classification is
independent of remote hints; argument-sensitive queries are checked locally.
"""
import re

READ_TOOLS = {
    'meeting': frozenset('''meeting_assets_get meeting_detail_get meeting_invitation_get meeting_invitees_list
        meeting_search meeting_summary_get meeting_summary_list meeting_summary_metadata_get
        meeting_summary_templates_list meeting_summary_trash_list meeting_transcript_get
        meeting_trashcan_list meeting_trashcan_metadata_get meeting_user_pmi_number_get'''.split()),
    'contact': frozenset('''contacts_group_query contacts_orgchart_query contacts_search'''.split()),
    'docs': frozenset('''canvas_data_table_list_columns canvas_data_table_list_tables canvas_data_table_query_rows
        docs_comment_list docs_file_get_content docs_file_get_general_access_policy
        docs_file_get_metadata_by_id docs_file_get_user_root_space_id docs_file_list_children
        docs_file_list_collaborators docs_file_metadata_tool docs_file_search docs_spec'''.split()),
    'team_chat': frozenset('''team_chat_channel_folder_fetch team_chat_channel_inactive_fetch team_chat_channel_members_get
        team_chat_channel_mention_group_members_get team_chat_channel_mention_groups_get
        team_chat_channel_search team_chat_contact_search
        team_chat_current_user_session_visit_metrics_fetch team_chat_emoji_list team_chat_file_search
        team_chat_message_fetch team_chat_messages_pinned_fetch team_chat_msg_bookmark_fetch
        team_chat_msg_context_fetch team_chat_msg_deep_links_get team_chat_msg_fetch
        team_chat_msg_get_by_id team_chat_msg_mention_me_fetch team_chat_msg_replies_fetch
        team_chat_msg_scheduled_fetch team_chat_msg_search team_chat_msg_sent_list
        team_chat_msg_unread_list team_chat_reminder_fetch team_chat_session_deep_links_get
        team_chat_session_metadata_fetch team_chat_session_recent_list team_chat_session_tab_fetch
        team_chat_specified_message_get team_chat_user_folders_get'''.split()),
    'calendar': frozenset('''calendar_get calendar_get_event calendar_get_inuse calendar_list calendar_list_events
        calendar_query_freebusy'''.split()),
    'accelerator': frozenset('''get_conversation_analysis get_conversation_comments get_conversation_transcript
        get_customer_accounts get_customer_contacts get_deal_activities get_deal_analysis
        get_deal_detail get_deal_stages get_manager_team_and_member get_scorecard_sessions
        search_conversations search_deals search_indicators search_internal_users'''.split()),
    'clips': frozenset('''avatar_list clip_analytics_activity_list clip_analytics_detail_list clip_analytics_overview_get
        clip_collaborator_list clip_comment_get clip_comment_list clip_get clip_list clip_transcript_get
        get_clip_metadata'''.split()),
    'docs_data_table': frozenset('''docs_data_table_fetch docs_file_metadata_tool docs_spec'''.split()),
    'mail': frozenset('''mcp_get_attachment mcp_get_message mcp_search_threads zmail_get_email zmail_list_emails
        zmail_list_labels'''.split()),
    'phone': frozenset('''phone_calllog_search phone_callsummary_get phone_get_my_setting phone_list_auto_receptionists
        phone_list_call_queues phone_list_calling_plans phone_list_phone_numbers phone_list_sites
        phone_list_users phone_recording_search phone_recording_transcript_get
        phone_sms_session_message_list phone_sms_session_search phone_voicemail_search
        phone_voicemail_transcript_get'''.split()),
    'recording': frozenset('''recording_content_get recording_id_search recording_meta_get recording_recent_list_search
        recording_search_my_recordings recording_share_list_search recording_share_search'''.split()),
    'sheets': frozenset('''docs_file_search sheets_describe_spreadsheet sheets_describe_worksheet sheets_discover_tables
        sheets_read_cells'''.split()),
    'tasks': frozenset('''tasks_assignees_get tasks_collaborators_get tasks_comments_get tasks_get tasks_list
        tasks_step_get tasks_steps_list'''.split()),
    'webinar': frozenset('''webinar_assets_get webinar_detail_get webinar_invitation_get webinar_panelist_search
        webinar_search webinar_summary_get webinar_summary_metadata_get webinar_template_list
        webinar_transcript_get webinar_trashcan_list webinar_trashcan_metadata_get
        zoomevents_attendees_search zoomevents_events_get zoomevents_events_metadata_get
        zoomevents_events_search zoomevents_roles_search'''.split()),
    'whiteboard': frozenset('''whiteboard_collaborators_get_v2 whiteboard_content_get whiteboard_get whiteboard_list'''.split()),
    'workspace': frozenset('''settings_workspace_account_setting_get settings_workspace_location_setting_get
        settings_workspace_setting_get settings_workspace_user_setting_get
        workspace_accessible_location_list workspace_assets_list workspace_calendar_events_get
        workspace_contacts_list workspace_list workspace_meeting_list workspace_metadata_get_asset
        workspace_metadata_get_location workspace_metadata_get_meeting workspace_metadata_get_user
        workspace_metadata_get_workspace workspace_pre_reservation_knowledge_get
        workspace_reservation_list workspace_search workspace_user_search'''.split()),
}

WRITE_TOOLS = {
    'accelerator': frozenset(),
    'calendar': frozenset('''calendar_delete_event calendar_insert_event calendar_patch_event'''.split()),
    'clips': frozenset('''clip_collaborator_create clip_collaborator_delete clip_comment_delete clip_comment_reply
        clip_create clip_delete clip_transcript_generate clip_update edit_restore_trim trim_clip'''.split()),
    'contact': frozenset(),
    'docs': frozenset('''canvas_create_file canvas_data_table_create canvas_data_table_create_column
        canvas_data_table_create_rows canvas_data_table_delete_column canvas_data_table_delete_rows
        canvas_data_table_update_column canvas_data_table_update_metadata canvas_data_table_update_rows
        docs_comment_create docs_file_add_collaborators docs_file_append_content docs_file_create
        docs_file_create_with_content docs_file_delete docs_file_delete_block docs_file_insert_blocks
        docs_file_modify_collaborators docs_file_modify_general_access_policy docs_file_modify_metadata
        docs_file_remove_collaborator docs_file_replace_content docs_file_replace_range_of_blocks
        docs_file_transfer_ownership docs_file_update_block'''.split()),
    'docs_data_table': frozenset('''docs_data_table_chart docs_data_table_create docs_data_table_row docs_data_table_schema
        docs_data_table_view'''.split()),
    'mail': frozenset('''mcp_send_message zmail_create_draft zmail_delete_draft zmail_modify_email zmail_send_draft
        zmail_update_draft'''.split()),
    'meeting': frozenset('''meeting_alternative_hosts_update meeting_basic_update meeting_create meeting_delete
        meeting_feature_update meeting_invitees_update meeting_roles_update meeting_summary_delete
        meeting_summary_share meeting_trashcan_action meeting_user_pmi_number_update'''.split()),
    'phone': frozenset('''phone_assign_members_to_call_queue phone_assign_numbers_to_auto_receptionist
        phone_assign_numbers_to_call_queue phone_create_auto_receptionist phone_create_call_queue
        phone_create_phone_user phone_remove_phone_user phone_update_my_setting
        phone_update_user_calling_plan'''.split()),
    'recording': frozenset('''recording_clip_push recording_share_update recording_transcript_generate'''.split()),
    'sheets': frozenset('''sheets_add_worksheet sheets_create_spreadsheet sheets_delete_worksheet sheets_edit_cells
        sheets_update_worksheet'''.split()),
    'tasks': frozenset('''task_trash task_update tasks_assignee_add tasks_assignee_remove tasks_collaborators_add
        tasks_collaborators_remove tasks_comment_add tasks_comment_delete tasks_create tasks_step_update
        tasks_steps_create tasks_steps_delete tasks_steps_reorder'''.split()),
    'team_chat': frozenset('''team_chat_channel_archive_status_update team_chat_channel_create team_chat_channel_delete
        team_chat_channel_folder_create team_chat_channel_folder_delete
        team_chat_channel_folder_move_items team_chat_channel_folder_remove_items
        team_chat_channel_folder_update team_chat_channel_leave team_chat_channel_member_add
        team_chat_channel_member_role_update team_chat_channel_members_remove
        team_chat_channel_mention_group_members_add team_chat_channel_mention_group_members_remove
        team_chat_channel_mention_groups_create team_chat_channel_mention_groups_delete
        team_chat_channel_mute_status_update team_chat_channel_update team_chat_contact_add
        team_chat_file_share team_chat_file_unshare team_chat_message_emoji_reaction
        team_chat_message_read_status_update team_chat_message_unread_marker_update team_chat_msg_delete
        team_chat_msg_reminder_create team_chat_msg_reminder_delete
        team_chat_msg_reply_to_trigger_thread team_chat_msg_send team_chat_msg_update
        team_chat_scheduled_message_delete team_chat_session_content_tab_create
        team_chat_session_content_tab_delete team_chat_session_read_position_update
        team_chat_shared_space_create'''.split()),
    'webinar': frozenset('''webinar_panelist_remove webinar_panelist_update webinar_roles_update webinar_trashcan_action'''.split()),
    'whiteboard': frozenset('''whiteboard_brainstorming_create whiteboard_collaborator_delete whiteboard_collaborator_update
        whiteboard_collaborators_add whiteboard_content_delete whiteboard_content_save whiteboard_create
        whiteboard_delete whiteboard_meeting_summary_create whiteboard_mermaid_script_create
        whiteboard_strategy_analysis_create whiteboard_update'''.split()),
    'workspace': frozenset('''settings_workspace_account_setting_update settings_workspace_location_setting_update
        settings_workspace_setting_update settings_workspace_user_setting_update
        workspace_reservation_create workspace_reservation_delete workspace_reservation_update'''.split()),
}

DOCUMENT_WRITE_TOOLS = frozenset('docs_file_create_with_content docs_file_insert_blocks docs_file_update_block docs_file_replace_range_of_blocks docs_file_modify_metadata'.split())


def operation_kind(service, tool, arguments=None):
    """No command/query endpoint may gain write access through zoom_read."""
    if tool in WRITE_TOOLS.get(service, ()):
        return 'write'
    if tool not in READ_TOOLS.get(service, ()):
        return None
    arguments = arguments or {}
    if service == 'docs_data_table' and tool == 'docs_data_table_fetch':
        sql = arguments.get('sql')
        if arguments.get('type') == 'row' or sql is not None:
            if (not isinstance(sql, str) or not re.match(r'^\s*SELECT\b', sql, re.I)
                    or ';' in sql or '--' in sql or '/*' in sql
                    or re.search(r'\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|PRAGMA|ATTACH|DETACH|VACUUM|LOAD_EXTENSION|INTO)\b', sql, re.I)):
                return 'unsafe_query'
    return 'read'


def operation_effects(service, tool, arguments):
    """Describe actual scope for the existing authorization gate, not a new grant."""
    effects = []
    if any(word in tool for word in ('delete', 'remove', 'trash', 'leave')) or arguments.get('command') == 'delete':
        effects.append('destructive')
    if (arguments.get('deleteForever') is True or arguments.get('mode') == 'hard'
            or any(arguments.get(key) for key in ('deleteRows', 'deleteColumns', 'clearRanges'))
            or re.search(r'\bDROP\b', str(arguments.get('statements', '')), re.I)):
        effects.append('destructive')
    if any(word in tool for word in ('send', 'reply', 'share', 'collaborator', 'invitee', 'roles', 'assignee', 'contact_add')):
        effects.append('external_or_access_change')
    if (service == 'phone' or tool.startswith('settings_workspace_')
            or 'transfer_ownership' in tool or 'access_policy' in tool):
        effects.append('account_or_access_change')
    if arguments.get('followingEvents') is True or arguments.get('recurrence'):
        effects.append('recurring_series')
    return sorted(set(effects))
