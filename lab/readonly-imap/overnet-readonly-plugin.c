/* GPL-3.0-only. Local test-only Overnet INBOX storage adapter.
 * Dovecot owns IMAP/MIME parsing; Store owns identifiers and exact Blossom bytes.
 * No daemon, login/authentication, listener, or durable derived mailbox. */
#include "lib.h"
#include "istream.h"
#include "index-mail.h"
#include "raw-storage.h"
#include "mailbox-list-private.h"
#include "mailbox-tree.h"
#include "imap-common.h"
#include "imap-commands.h"
#include "bridge-io.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if DOVECOT_VERSION_MAJOR != 2 || DOVECOT_VERSION_MINOR != 4 || DOVECOT_VERSION_MICRO != 5
#error This local integration requires exactly Dovecot 2.4.5 and matching headers
#endif

#define MAX_MESSAGES 4096U
#define MAX_MESSAGE_BYTES 10485760U
#define SNAPSHOT_LIMIT (64U + MAX_MESSAGES * 24U)

extern struct mail_storage raw_storage;
extern struct mailbox raw_mailbox;
const char *overnet_readonly_plugin_version = DOVECOT_ABI_VERSION;
static struct mail_storage readonly_storage;
static struct mail_vfuncs readonly_mail_vfuncs;
static MODULE_CONTEXT_DEFINE_INIT(readonly_module, &mail_storage_module_register);

struct entry { uint32_t uid; uint64_t received_at; };
struct readonly_box {
    union mailbox_module_context module_ctx;
    struct entry *entries;
    uint32_t count, uidvalidity, uidnext;
};
#define BOX_CONTEXT(box) MODULE_CONTEXT_REQUIRE(box, readonly_module)

/* Strict canonical decimal framing: no signs, leading zeroes, overflow, embedded
 * NULs, trailing junk or platform-width conversions. Binary body is separate. */
static int number(const unsigned char **cursor, const unsigned char *end,
                  unsigned char delimiter, uint64_t max, uint64_t *value)
{
    const unsigned char *p = *cursor, *start = p;
    uint64_t n = 0;
    while (p < end && *p >= '0' && *p <= '9') {
        unsigned int digit = *p - '0';
        if (digit > max || n > (max - digit) / 10)
            return -1;
        n = n * 10 + digit;
        p++;
    }
    if (p == start || (p - start > 1 && *start == '0') || p == end || *p != delimiter)
        return -1;
    *cursor = p + 1;
    *value = n;
    return 0;
}

static int bridge(struct mailbox *box, const char *request, size_t limit,
                  unsigned char **response, size_t *length)
{
    if (overnet_bridge_request(getenv("OVERNET_IMAP_HELPER"),
            getenv("OVERNET_IMAP_CONFIG"), request, limit, response, length) < 0) {
        mail_storage_set_error(box->storage, MAIL_ERROR_TEMP,
                               "Overnet local reader unavailable");
        return -1;
    }
    return 0;
}

static int invalid_response(struct mailbox *box)
{
    mail_storage_set_error(box->storage, MAIL_ERROR_TEMP,
                           "Overnet local reader returned invalid data");
    return -1;
}

static int read_snapshot(struct mailbox *box, struct readonly_box *snapshot)
{
    unsigned char *response;
    const unsigned char *p, *end;
    size_t length;
    uint64_t validity, next, count, uid, timestamp;
    uint32_t previous = 0, i;
    int ret = -1;
    if (bridge(box, "SNAPSHOT\n", SNAPSHOT_LIMIT, &response, &length) < 0)
        return -1;
    p = response; end = response + length;
    if (length < 3 || memcmp(p, "OK ", 3) != 0)
        goto done;
    p += 3;
    if (number(&p, end, ' ', UINT32_MAX, &validity) < 0 || validity == 0 ||
        number(&p, end, ' ', UINT32_MAX, &next) < 0 || next == 0 ||
        number(&p, end, '\n', MAX_MESSAGES, &count) < 0)
        goto done;
    snapshot->entries = i_new(struct entry, count == 0 ? 1 : count);
    snapshot->uidvalidity = (uint32_t)validity;
    snapshot->uidnext = (uint32_t)next;
    snapshot->count = (uint32_t)count;
    for (i = 0; i < count; i++) {
        if (number(&p, end, ' ', UINT32_MAX - 1U, &uid) < 0 ||
            uid <= previous || uid >= next ||
            number(&p, end, '\n', UINT64_C(9999999999), &timestamp) < 0 ||
            (uint64_t)(time_t)timestamp != timestamp)
            goto done;
        snapshot->entries[i].uid = previous = (uint32_t)uid;
        snapshot->entries[i].received_at = timestamp;
    }
    if (p != end)
        goto done;
    ret = 0;
done:
    free(response);
    if (ret < 0) {
        i_free(snapshot->entries);
        return invalid_response(box);
    }
    return 0;
}

static const struct entry *entry_for_mail(struct mail *mail)
{
    struct readonly_box *ctx = BOX_CONTEXT(mail->box);
    uint32_t i;
    for (i = 0; i < ctx->count; i++) {
        if (ctx->entries[i].uid == mail->uid)
            return &ctx->entries[i];
    }
    mail_storage_set_error(mail->box->storage, MAIL_ERROR_NOTFOUND,
                           "Overnet selected UID not found");
    return NULL;
}

static int readonly_stream(struct mail *mail, bool body ATTR_UNUSED,
                           struct message_size *hdr_size,
                           struct message_size *body_size,
                           struct istream **stream_r)
{
    struct index_mail *imail = INDEX_MAIL(mail);
    unsigned char *response;
    const unsigned char *p, *end;
    size_t length;
    uint64_t size;
    if (entry_for_mail(mail) == NULL)
        return -1;
    if (imail->data.stream == NULL) {
        if (!mail_stream_access_start(mail))
            return -1;
        if (bridge(mail->box, t_strdup_printf("FETCH %u\n", mail->uid),
                   MAX_MESSAGE_BYTES + 64U, &response, &length) < 0)
            return -1;
        p = response; end = response + length;
        if (length < 5 || memcmp(p, "DATA ", 5) != 0) {
            free(response);
            return invalid_response(mail->box);
        }
        p += 5;
        if (number(&p, end, '\n', MAX_MESSAGE_BYTES, &size) < 0 || size == 0 ||
            (uint64_t)(end - p) != size) {
            free(response);
            return invalid_response(mail->box);
        }
        /* The data pool is cleared when this mail object advances to another
         * sequence. No accumulated mailbox-sized body cache or message files. */
        imail->data.stream = i_stream_create_from_data(
            p_memdup(imail->mail.data_pool, p, (size_t)size), (size_t)size);
        imail->data.physical_size = size;
        free(response);
    }
    return index_mail_init_stream(imail, hdr_size, body_size, stream_r);
}

static int readonly_size(struct mail *mail, uoff_t *size_r)
{
    struct istream *stream;
    struct index_mail *imail = INDEX_MAIL(mail);
    if (imail->data.physical_size == UOFF_T_MAX &&
        readonly_stream(mail, TRUE, NULL, NULL, &stream) < 0)
        return -1;
    *size_r = imail->data.physical_size;
    return 0;
}

static int readonly_date(struct mail *mail, time_t *date_r)
{
    const struct entry *entry = entry_for_mail(mail);
    if (entry == NULL)
        return -1;
    *date_r = (time_t)entry->received_at;
    return 0;
}

static int readonly_save_date(struct mail *mail, time_t *date_r)
{
    return readonly_date(mail, date_r) < 0 ? -1 : 1;
}

static int readonly_special(struct mail *mail, enum mail_fetch_field field,
                            const char **value_r)
{
    if (field == MAIL_FETCH_FROM_ENVELOPE || field == MAIL_FETCH_STORAGE_ID) {
        *value_r = "";
        return 0;
    }
    return index_mail_get_special(mail, field, value_r);
}

static int readonly_exists(struct mailbox *box, bool auto_boxes ATTR_UNUSED,
                           enum mailbox_existence *existence_r)
{
    *existence_r = strcmp(box->name, "INBOX") == 0 ?
        MAILBOX_EXISTENCE_SELECT : MAILBOX_EXISTENCE_NONE;
    return 0;
}

static int readonly_open(struct mailbox *box)
{
    if (strcmp(box->name, "INBOX") != 0) {
        mail_storage_set_error(box->storage, MAIL_ERROR_NOTFOUND,
                               "Only the selected local INBOX exists");
        return -1;
    }
    return index_storage_mailbox_open(box, TRUE);
}

static struct mailbox_sync_context *
readonly_sync(struct mailbox *box, enum mailbox_sync_flags flags)
{
    struct readonly_box *old = BOX_CONTEXT(box), snapshot;
    struct mail_index_sync_ctx *ctx;
    struct mail_index_view *view;
    struct mail_index_transaction *trans;
    struct mail_index_sync_rec rec;
    uint32_t seq, i;
    int ret = -1;
    i_zero(&snapshot);
    if (read_snapshot(box, &snapshot) < 0)
        goto done;
    if (old->uidvalidity != 0) {
        if (snapshot.uidvalidity != old->uidvalidity || snapshot.uidnext < old->uidnext ||
            snapshot.count < old->count)
            goto invalid;
        for (i = 0; i < old->count; i++) {
            if (snapshot.entries[i].uid != old->entries[i].uid ||
                snapshot.entries[i].received_at != old->entries[i].received_at)
                goto invalid;
        }
        if (snapshot.count > old->count && snapshot.entries[old->count].uid < old->uidnext)
            goto invalid;
        if (snapshot.uidnext == old->uidnext && snapshot.count == old->count) {
            ret = 0;
            goto done;
        }
    }
    ret = mail_index_sync_begin(box->index, &ctx, &view, &trans,
                               index_storage_get_sync_flags(box));
    if (ret > 0) {
        mail_index_update_header(trans,
            offsetof(struct mail_index_header, uid_validity),
            &snapshot.uidvalidity, sizeof(snapshot.uidvalidity), TRUE);
        for (i = old->count; i < snapshot.count; i++)
            mail_index_append(trans, snapshot.entries[i].uid, &seq);
        mail_index_update_header(trans,
            offsetof(struct mail_index_header, next_uid),
            &snapshot.uidnext, sizeof(snapshot.uidnext), FALSE);
        while (mail_index_sync_next(ctx, &rec)) { }
        ret = mail_index_sync_commit(&ctx);
        if (ret == 0) {
            i_free(old->entries);
            old->entries = snapshot.entries;
            snapshot.entries = NULL;
            old->count = snapshot.count;
            old->uidvalidity = snapshot.uidvalidity;
            old->uidnext = snapshot.uidnext;
        }
    }
    if (ret < 0)
        mailbox_set_index_error(box);
    goto done;
invalid:
    ret = invalid_response(box);
done:
    i_free(snapshot.entries);
    return index_mailbox_sync_init(box, flags, ret < 0);
}

/* READONLY alone is not sufficient for inherited raw-storage save callbacks.
 * Explicit rejection retains the mature backend's context lifetime conventions. */
static struct mail_save_context *readonly_save_alloc(struct mailbox_transaction_context *t)
{
    if (t->save_ctx == NULL) {
        t->save_ctx = i_new(struct mail_save_context, 1);
        t->save_ctx->transaction = t;
    }
    return t->save_ctx;
}
static int readonly_save_begin(struct mail_save_context *ctx, struct istream *input ATTR_UNUSED)
{
    mail_storage_set_error(ctx->transaction->box->storage, MAIL_ERROR_NOTPOSSIBLE,
                           "Overnet local INBOX is read-only");
    return -1;
}
static void readonly_save_cancel(struct mail_save_context *ctx) { index_save_context_free(ctx); }
static void readonly_save_rollback(struct mail_save_context *ctx) { i_free(ctx); }
static int readonly_save_commit_pre(struct mail_save_context *ctx)
{
    mail_storage_set_error(ctx->transaction->box->storage, MAIL_ERROR_NOTPOSSIBLE,
                           "Overnet local INBOX is read-only");
    i_free(ctx);
    return -1;
}
static void readonly_free(struct mailbox *box)
{
    struct readonly_box *ctx = BOX_CONTEXT(box);
    i_free(ctx->entries);
    ctx->module_ctx.super.free(box);
}

static struct mailbox *readonly_box_alloc(struct mail_storage *storage,
        struct mailbox_list *list, const char *name, enum mailbox_flags flags)
{
    struct mailbox *box = raw_storage.v.mailbox_alloc(storage, list, name,
        flags | MAILBOX_FLAG_READONLY | MAILBOX_FLAG_NO_INDEX_FILES);
    struct readonly_box *ctx = p_new(box->pool, struct readonly_box, 1);
    ctx->module_ctx.super = box->v;
    MODULE_CONTEXT_SET(box, readonly_module, ctx);
    if (list->subscriptions == NULL)
        list->subscriptions = mailbox_tree_init('/');
    box->v.save_alloc = readonly_save_alloc;
    box->v.save_begin = readonly_save_begin;
    box->v.save_cancel = readonly_save_cancel;
    box->v.transaction_save_rollback = readonly_save_rollback;
    box->v.transaction_save_commit_pre = readonly_save_commit_pre;
    box->v.exists = readonly_exists;
    box->v.open = readonly_open;
    box->v.free = readonly_free;
    box->v.sync_init = readonly_sync;
    box->mail_vfuncs = &readonly_mail_vfuncs;
    return box;
}
static struct mail_storage *readonly_alloc(void)
{
    struct mail_storage *storage = raw_storage.v.alloc();
    storage->name = readonly_storage.name;
    storage->class_flags = readonly_storage.class_flags;
    storage->v = readonly_storage.v;
    return storage;
}

/* Dovecot normally allows temporary STORE flags on a read-only SELECT and
 * treats EXAMINE STORE/EXPUNGE as ignored success. This local adapter instead
 * rejects every explicit mutation. Dovecot still parses/drains the input. */
static bool reject_mutation(struct client_command_context *cmd)
{
    client_send_tagline(cmd, "NO [NOPERM] Overnet local INBOX is read-only.");
    return TRUE;
}
static void guard_command(struct client_command_context *cmd)
{
    static const char *const mutations[] = {
        "APPEND", "STORE", "UID STORE", "COPY", "UID COPY", "MOVE", "UID MOVE",
        "REPLACE", "UID REPLACE", "EXPUNGE", "UID EXPUNGE", "CREATE", "DELETE",
        "RENAME", "SUBSCRIBE", "UNSUBSCRIBE", "SETMETADATA", "SETQUOTA", "SETACL",
        "DELETEACL", NULL
    };
    unsigned int i;
    for (i = 0; mutations[i] != NULL; i++) {
        if (strcasecmp(cmd->name, mutations[i]) == 0) {
            cmd->func = reject_mutation;
            return;
        }
    }
}
static void after_command(struct client_command_context *cmd ATTR_UNUSED) { }

void overnet_readonly_plugin_init(struct module *module ATTR_UNUSED);
void overnet_readonly_plugin_deinit(void);
void overnet_readonly_plugin_init(struct module *module ATTR_UNUSED)
{
    readonly_mail_vfuncs = raw_mail_vfuncs;
    readonly_mail_vfuncs.get_stream = readonly_stream;
    readonly_mail_vfuncs.get_physical_size = readonly_size;
    readonly_mail_vfuncs.get_received_date = readonly_date;
    readonly_mail_vfuncs.get_save_date = readonly_save_date;
    readonly_mail_vfuncs.get_special = readonly_special;
    readonly_storage = raw_storage;
    readonly_storage.name = "overnet_readonly";
    readonly_storage.class_flags = MAIL_STORAGE_CLASS_FLAG_NO_ROOT | MAIL_STORAGE_CLASS_FLAG_BINARY_DATA;
    readonly_storage.v.alloc = readonly_alloc;
    readonly_storage.v.mailbox_alloc = readonly_box_alloc;
    mail_storage_class_register(&readonly_storage);
    command_hook_register(guard_command, after_command);
}
void overnet_readonly_plugin_deinit(void)
{
    command_hook_unregister(guard_command, after_command);
    mail_storage_class_unregister(&readonly_storage);
}
