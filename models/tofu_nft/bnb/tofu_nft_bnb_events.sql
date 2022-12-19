{{ config(
    alias = 'events',
    partition_by = ['block_date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_time', 'unique_trade_id']
    )
}}

WITH decoded AS(
    SELECT
            run.call_tx_hash AS tx_hash,
            run.call_block_time AS block_time,
            run.call_block_number AS block_number,
            run.contract_address AS project_contract_address,
            event.evt_index,
            JSON_VALUE(event.inventory, 'lax $.currency') currency_contract,
            JSON_VALUE(run.detail, 'lax $.price') amount_raw,
            JSON_VALUE(run.detail, 'lax $.incentiveRate') incentiveRate,
            JSON_VALUE(event.inventory, 'lax $.buyer') buyer,
            JSON_VALUE(event.inventory, 'lax $.seller') seller,
            JSON_VALUE(run.detail, 'lax $.bundle[*]') bundle
    FROM {{source('tofu_nft_bnb', 'MarketNG_call_run')}} run
    LEFT JOIN {{source('tofu_nft_bnb', 'MarketNG_evt_EvInventoryUpdate')}} event ON event.evt_tx_hash = run.call_tx_hash
    AND run.call_tx_hash IS NOT NULL
    AND JSON_VALUE(event.inventory, 'lax $.seller') NOT LIKE '%0x000000000000000000000000%'
    {% if is_incremental() %}
    WHERE call_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}    
), events AS (
    SELECT 
        'bnb' AS blockchain,
        'tofu' AS project,
        'v1' AS version,
        block_time,
        JSON_VALUE(bundle, 'lax $.tokenId') AS token_id,
        'erc721' AS token_standard,
        'Single Item Trade' AS trade_type,
        CAST(JSON_VALUE(bundle, 'lax $.amount') AS INTEGER) AS number_of_items, 
        'Buy' AS trade_category,
        buyer,
        seller,
        CAST(amount_raw AS double) amount_raw,
        CASE 
            WHEN currency_contract = '0x0000000000000000000000000000000000000000' THEN '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c'
            ELSE currency_contract
        END currency_contract,
        'BNB' AS currency_symbol,
        JSON_VALUE(bundle, 'strict $.token') AS nft_contract_address,
        project_contract_address,
        tx_hash,
        block_number,
        evt_index,
        CAST(incentiveRate AS double)/power(10,6) incentiveRate
FROM decoded
)
    SELECT 
        events.blockchain,
        events.project,
        events.version,
        events.block_time,
        date_trunc('day', events.block_time) AS block_date,
        events.token_id,
        bnb_nft_tokens.name collection,
        events.amount_raw/POWER(10, bnb_bep20_tokens.decimals)*prices.price AS amount_usd,
        events.token_standard,
        CASE 
            WHEN number_of_items > 1  THEN 'Bundle Trade' 
            ELSE 'Single Item Trade' 
        END AS trade_type,
        CAST(events.number_of_items AS DECIMAL(38,0)) AS number_of_items,
        events.trade_category,
        'Trade' AS evt_type,
        events.seller,
        events.buyer,
        events.amount_raw/POWER(10, bnb_bep20_tokens.decimals) AS amount_original,
        CAST(events.amount_raw AS DECIMAL(38,0)) AS amount_raw,
        COALESCE(events.currency_symbol, bnb_bep20_tokens.symbol) AS currency_symbol,
        events.currency_contract,
        events.nft_contract_address,
        events.project_contract_address,
        agg.name AS aggregator_name,
        CASE WHEN agg.name IS NOT NULL THEN agg.contract_address END AS aggregator_address,
        events.tx_hash,
        events.block_number,
        bt.from AS tx_from,
        bt.to AS tx_to,
        events.incentiveRate * events.amount_raw AS platform_fee_amount_raw,
        events.incentiveRate * (events.amount_raw/POWER(10, bnb_bep20_tokens.decimals)) AS platform_fee_amount,
        incentiveRate * (events.amount_raw/POWER(10, bnb_bep20_tokens.decimals)*prices.price) AS platform_fee_amount_usd,
        events.incentiveRate AS platform_fee_percentage,
        events.block_number || events.tx_hash || events.evt_index AS unique_trade_id

    FROM events
    LEFT JOIN {{ ref('nft_aggregators') }} agg ON events.buyer=agg.contract_address AND agg.blockchain='bnb'
    LEFT JOIN {{ ref('tokens_erc20') }} bnb_bep20_tokens ON bnb_bep20_tokens.contract_address=events.currency_contract AND bnb_bep20_tokens.blockchain='bnb'
    LEFT JOIN {{ ref('tokens_nft') }} bnb_nft_tokens ON bnb_nft_tokens.contract_address=events.currency_contract AND bnb_nft_tokens.blockchain='bnb'
    LEFT JOIN {{ source('prices', 'usd') }} prices ON prices.minute=date_trunc('minute', events.block_time)
    AND (prices.contract_address=events.currency_contract AND prices.blockchain=events.blockchain)
        {% if is_incremental() %}
        AND prices.minute >= date_trunc("day", now() - interval '1 week')
        {% endif %}
    INNER JOIN {{ source('bnb','transactions') }} bt ON bt.hash=events.tx_hash
    AND bt.block_time=events.block_time
        {% if is_incremental() %}
        AND bt.block_time >= date_trunc("day", now() - interval '1 week')
        {% endif %}

