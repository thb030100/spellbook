WITH decoded AS(
    SELECT
            run.call_tx_hash AS tx_hash,
            run.call_block_time AS block_time,
            run.call_block_number AS block_number,
            run.contract_address AS project_contract_address,
            event.evt_index,
            JSON_QUERY(run.detail, 'strict $.currency') AS currency_contract,
            JSON_QUERY(run.detail, 'strict $.price') AS amount_raw,
            JSON_QUERY(run.detail, 'strict $.incentiveRate') AS incentiveRate,
            JSON_QUERY(event.inventory, 'strict $.buyer') AS buyer,     
            JSON_QUERY(event.inventory, 'strict $.seller') AS seller,   
            replace(replace(replace(replace(replace(JSON_QUERY(run.detail, 'strict $.bundle'), '\',''),'[',''), ']',''),'"{','{'),'}"','}') bundle
            
    FROM tofu_nft_bnb.MarketNG_call_run run
    LEFT JOIN tofu_nft_bnb.MarketNG_evt_EvInventoryUpdate event ON event.evt_tx_hash = run.call_tx_hash
    WHERE date_trunc('day',call_block_time) >= timestamp '2022-01-01'
), events AS (
    SELECT 
        'bnb' AS blockchain,
        'pancakeswap' AS project,
        'v1' AS version,
        block_time,
        JSON_QUERY(bundle, 'strict $.tokenId') AS token_id,
        'erc721' AS token_standard,
        'Single Item Trade' AS trade_type,
        JSON_QUERY(bundle, 'strict $.amount') AS number_of_items, 
        'Buy' AS trade_category,
        buyer,
        seller,
        CAST(amount_raw AS double) amount_raw,
        currency_contract,
        'BNB' AS currency_symbol,
        JSON_QUERY(bundle, 'strict $.token') AS nft_contract_address,
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

