module tiu::tiu{
   public struct TIU has drop{} 

   // Constants
   const DECIMALS: u8 = 6;

   fun init(witness: TIU, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let decimals = DECIMALS;
        let symbol = b"TIU";
        let name = b"TUI COIN";
        let description = b"TUI COIN is a coin for the TUI project";
        let icon_url = option::some(sui::url::new_unsafe_from_bytes(b"https://static.vecteezy.com/system/resources/previews/011/947/129/original/gold-internet-icon-free-png.png"));
        let supply = 10_000_000_000_000_000;

        let (mut treasury_cap, metadata) = sui::coin::create_currency(
            witness,
            decimals,
            symbol,
            name,
            description,
            icon_url,
            ctx
        );

        transfer::public_freeze_object(metadata);
        sui::coin::mint_and_transfer(&mut treasury_cap, supply, sender, ctx);

        transfer::public_transfer(treasury_cap, sender);
   }
}