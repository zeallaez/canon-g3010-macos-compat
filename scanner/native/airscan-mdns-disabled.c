#include "airscan.h"

struct mdns_resolver {
    int ifindex;
};

struct mdns_query {
    char *name;
    const ip_addrset *answer;
    void *ptr;
};

void
mdns_initscan_timer_expired(void)
{
}

SANE_Status
mdns_init(void)
{
    zeroconf_finding_done(ZEROCONF_MDNS_HINT);
    zeroconf_finding_done(ZEROCONF_USCAN_TCP);
    zeroconf_finding_done(ZEROCONF_USCANS_TCP);
    return SANE_STATUS_GOOD;
}

void
mdns_cleanup(void)
{
}

mdns_resolver*
mdns_resolver_new(int ifindex)
{
    mdns_resolver *resolver = mem_new(mdns_resolver, 1);
    resolver->ifindex = ifindex;
    return resolver;
}

void
mdns_resolver_free(mdns_resolver *resolver)
{
    mem_free(resolver);
}

void
mdns_resolver_cancel(mdns_resolver *resolver)
{
    (void) resolver;
}

bool
mdns_resolver_has_pending(mdns_resolver *resolver)
{
    (void) resolver;
    return false;
}

mdns_query*
mdns_query_submit(mdns_resolver *resolver, const char *name,
                  void (*callback)(const mdns_query *query), void *ptr)
{
    (void) resolver;
    mdns_query *query = mem_new(mdns_query, 1);
    query->name = str_dup(name);
    query->ptr = ptr;
    callback(query);
    return query;
}

void
mdns_query_cancel(mdns_query *query)
{
    if (query != NULL) {
        mem_free(query->name);
        mem_free(query);
    }
}

const char*
mdns_query_get_name(const mdns_query *query)
{
    return query->name;
}

const ip_addrset*
mdns_query_get_answer(const mdns_query *query)
{
    return query->answer;
}

void*
mdns_query_get_ptr(const mdns_query *query)
{
    return query->ptr;
}

unsigned int
mdns_device_count_by_model(int ifindex, const char *pattern)
{
    (void) ifindex;
    (void) pattern;
    return 0;
}
