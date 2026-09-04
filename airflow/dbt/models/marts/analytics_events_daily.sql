with events as (
    select * from {{ ref('stg_events') }}
)

select
    date_trunc('day', event_created_at) as event_date,
    event_type,
    currency,
    count(*)          as event_count,
    sum(amount)        as total_amount,
    avg(amount)         as avg_amount
from events
group by 1, 2, 3
