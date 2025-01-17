////////////////////////////////
// Account contract
////////////////////////////////
#[starknet::contract]
mod Account {
    use starknet::{
        get_tx_info, get_caller_address, get_contract_address, get_block_timestamp, ContractAddress,
        account::Call, call_contract_syscall, replace_class_syscall, ClassHash, SyscallResultTrait
    };
    use ecdsa::check_ecdsa_signature;
    use array::{SpanTrait, ArrayTrait};
    use box::BoxTrait;
    use option::OptionTrait;
    use zeroable::Zeroable;
    use token_bound_accounts::interfaces::IERC721::{IERC721DispatcherTrait, IERC721Dispatcher};
    use token_bound_accounts::interfaces::IAccount::IAccount;

    // SRC5 interface for token bound accounts
    const TBA_INTERFACE_ID: felt252 =
        0x539036932a2ab9c4734fbfd9872a1f7791a3f577e45477336ae0fd0a00c9ff;

    #[storage]
    struct Storage {
        _token_contract: ContractAddress, // contract address of NFT
        _token_id: u256, // token ID of NFT
        _unlock_timestamp: u64, // time to unlock account when locked
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        AccountCreated: AccountCreated,
        AccountUpgraded: AccountUpgraded,
        AccountLocked: AccountLocked,
        TransactionExecuted: TransactionExecuted
    }

    /// @notice Emitted exactly once when the account is initialized
    /// @param owner The owner address
    #[derive(Drop, starknet::Event)]
    struct AccountCreated {
        #[key]
        owner: ContractAddress,
    }

    /// @notice Emitted when the account executes a transaction
    /// @param hash The transaction hash
    /// @param response The data returned by the methods called
    #[derive(Drop, starknet::Event)]
    struct TransactionExecuted {
        #[key]
        hash: felt252,
        response: Span<Span<felt252>>
    }

    /// @notice Emitted when the account upgrades to a new implementation
    /// @param account tokenbound account to be upgraded
    /// @param implementation the upgraded account class hash
    #[derive(Drop, starknet::Event)]
    struct AccountUpgraded {
        account: ContractAddress,
        implementation: ClassHash
    }

    /// @notice Emitted when the account is locked
    /// @param account tokenbound account who's lock function was triggered
    /// @param locked_at timestamp at which the lock function was triggered
    /// @param duration time duration for which the account remains locked
    #[derive(Drop, starknet::Event)]
    struct AccountLocked {
        #[key]
        account: ContractAddress,
        locked_at: u64,
        duration: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, token_contract: ContractAddress, token_id: u256) {
        self._token_contract.write(token_contract);
        self._token_id.write(token_id);

        let owner = self._get_owner(token_contract, token_id);
        self.emit(AccountCreated { owner });
    }

    #[external(v0)]
    impl IAccountImpl of IAccount<ContractState> {
        /// @notice used for signature validation
        /// @param hash The message hash 
        /// @param signature The signature to be validated
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Span<felt252>
        ) -> felt252 {
            self._is_valid_signature(hash, signature)
        }

        fn __validate_deploy__(
            self: @ContractState, class_hash: felt252, contract_address_salt: felt252,
        ) -> felt252 {
            self._validate_transaction()
        }

        fn __validate_declare__(self: @ContractState, class_hash: felt252) -> felt252 {
            self._validate_transaction()
        }

        /// @notice validate an account transaction
        /// @param calls an array of transactions to be executed
        fn __validate__(ref self: ContractState, mut calls: Array<Call>) -> felt252 {
            self._validate_transaction()
        }

        /// @notice executes a transaction
        /// @param calls an array of transactions to be executed
        fn __execute__(ref self: ContractState, mut calls: Array<Call>) -> Array<Span<felt252>> {
            self._assert_only_owner();
            let (lock_status, _) = self._is_locked();
            assert(!lock_status, 'Account: account is locked!');

            let tx_info = get_tx_info().unbox();
            assert(tx_info.version != 0, 'invalid tx version');

            let retdata = self._execute_calls(calls.span());
            let hash = tx_info.transaction_hash;
            let response = retdata.span();
            self.emit(TransactionExecuted { hash, response });
            retdata
        }

        /// @notice gets the token bound NFT owner
        /// @param token_contract the contract address of the NFT
        /// @param token_id the token ID of the NFT
        fn owner(
            self: @ContractState, token_contract: ContractAddress, token_id: u256
        ) -> ContractAddress {
            self._get_owner(token_contract, token_id)
        }

        /// @notice returns the contract address and token ID of the NFT
        fn token(self: @ContractState) -> (ContractAddress, u256) {
            self._get_token()
        }

        /// @notice ugprades an account implementation
        /// @param implementation the new class_hash
        fn upgrade(ref self: ContractState, implementation: ClassHash) {
            self._assert_only_owner();
            let (lock_status, _) = self._is_locked();
            assert(!lock_status, 'Account: account is locked!');
            assert(!implementation.is_zero(), 'Invalid class hash');
            replace_class_syscall(implementation).unwrap_syscall();
            self.emit(AccountUpgraded { account: get_contract_address(), implementation, });
        }

        // @notice protection mechanism for selling token bound accounts. can't execute when account is locked
        // @param duration for which to lock account
        fn lock(ref self: ContractState, duration: u64) {
            self._assert_only_owner();
            let (lock_status, _) = self._is_locked();
            assert(!lock_status, 'Account: account already locked');
            let current_timestamp = get_block_timestamp();
            let unlock_time = current_timestamp + duration;
            self._unlock_timestamp.write(unlock_time);
            self
                .emit(
                    AccountLocked {
                        account: get_contract_address(), locked_at: current_timestamp, duration
                    }
                );
        }

        // @notice returns account lock status and time left until account unlocks
        fn is_locked(self: @ContractState) -> (bool, u64) {
            return self._is_locked();
        }

        // @notice check that account supports TBA interface
        // @param interface_id interface to be checked against
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            if (interface_id == TBA_INTERFACE_ID) {
                return true;
            } else {
                return false;
            }
        }
    }

    #[generate_trait]
    impl internalImpl of InternalTrait {
        /// @notice check that caller is the token bound account
        fn _assert_only_owner(ref self: ContractState) {
            let caller = get_caller_address();
            let owner = self._get_owner(self._token_contract.read(), self._token_id.read());
            assert(caller == owner, 'Account: unathorized');
        }

        /// @notice internal function for getting NFT owner
        /// @param token_contract contract address of NFT
        // @param token_id token ID of NFT
        // NB: This function aims for compatibility with all contracts (snake or camel case) but do not work as expected on mainnet as low level calls do not return err at the moment. Should work for contracts which implements CamelCase but not snake_case until starknet v0.15.
        fn _get_owner(
            self: @ContractState, token_contract: ContractAddress, token_id: u256
        ) -> ContractAddress {
            let mut calldata: Array<felt252> = ArrayTrait::new();
            Serde::serialize(@token_id, ref calldata);
            let mut res = call_contract_syscall(
                token_contract, selector!("ownerOf"), calldata.span()
            );
            if (res.is_err()) {
                res = call_contract_syscall(token_contract, selector!("owner_of"), calldata.span());
            }
            let mut address = res.unwrap();
            Serde::<ContractAddress>::deserialize(ref address).unwrap()
        }

        /// @notice internal transaction for returning the contract address and token ID of the NFT
        fn _get_token(self: @ContractState) -> (ContractAddress, u256) {
            let contract = self._token_contract.read();
            let tokenId = self._token_id.read();
            (contract, tokenId)
        }

        // @notice protection mechanism for TBA trading. Returns the lock-status (true or false), and the remaning time till account unlocks.
        fn _is_locked(self: @ContractState) -> (bool, u64) {
            let unlock_timestamp = self._unlock_timestamp.read();
            let current_time = get_block_timestamp();
            if (current_time < unlock_timestamp) {
                let time_until_unlocks = unlock_timestamp - current_time;
                return (true, time_until_unlocks);
            } else {
                return (false, 0_u64);
            }
        }

        /// @notice internal function for tx validation
        fn _validate_transaction(self: @ContractState) -> felt252 {
            let tx_info = get_tx_info().unbox();
            let tx_hash = tx_info.transaction_hash;
            let signature = tx_info.signature;
            assert(
                self._is_valid_signature(tx_hash, signature) == starknet::VALIDATED,
                'Account: invalid signature'
            );
            starknet::VALIDATED
        }

        /// @notice internal function for signature validation
        fn _is_valid_signature(
            self: @ContractState, hash: felt252, signature: Span<felt252>
        ) -> felt252 {
            let signature_length = signature.len();
            assert(signature_length == 2_u32, 'Account: invalid sig length');

            let caller = get_caller_address();
            let owner = self._get_owner(self._token_contract.read(), self._token_id.read());
            if (caller == owner) {
                return starknet::VALIDATED;
            } else {
                return 0;
            }
        }

        /// @notice internal function for executing transactions
        /// @param calls An array of transactions to be executed
        fn _execute_calls(ref self: ContractState, mut calls: Span<Call>) -> Array<Span<felt252>> {
            let mut result: Array<Span<felt252>> = ArrayTrait::new();
            let mut calls = calls;

            loop {
                match calls.pop_front() {
                    Option::Some(call) => {
                        match call_contract_syscall(
                            *call.to, *call.selector, call.calldata.span()
                        ) {
                            Result::Ok(mut retdata) => { result.append(retdata); },
                            Result::Err(revert_reason) => {
                                panic_with_felt252('multicall_failed');
                            }
                        }
                    },
                    Option::None(_) => { break (); }
                };
            };
            result
        }
    }
}
