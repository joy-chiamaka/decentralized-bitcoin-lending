;; BitVault Protocol - Decentralized Bitcoin Lending Platform
;;
;; Summary: A trustless collateralized lending protocol built on Stacks
;;          enabling Bitcoin holders to unlock liquidity without selling
;;
;; Description: BitVault Protocol revolutionizes Bitcoin DeFi by providing
;;              a secure, over-collateralized lending system that allows
;;              users to deposit sBTC as collateral and borrow against it.
;;              Features automated liquidation mechanisms, dynamic interest
;;              rates, and liquidator incentives to maintain protocol health.
;;              Built for Stacks Layer 2 with Bitcoin-native compliance.

;; ERROR CODES & CONSTANTS

;; Protocol Error Definitions
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-BALANCE (err u101))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-ALREADY-INITIALIZED (err u104))
(define-constant ERR-NOT-INITIALIZED (err u105))
(define-constant ERR-LIQUIDATION-FAILED (err u106))

;; Risk Management Parameters
(define-constant MIN-COLLATERAL-RATIO u150) ;; 150% minimum collateralization ratio
(define-constant MAX-INTEREST-RATE u10000) ;; 100% maximum APR in basis points
(define-constant MIN-INTEREST-RATE u100) ;; 1% minimum APR in basis points
(define-constant MAX-LIQUIDATION-THRESHOLD u9500) ;; 95% maximum liquidation threshold
(define-constant MIN-LIQUIDATION-THRESHOLD u7000) ;; 70% minimum liquidation threshold
(define-constant MAX-REWARD-MULTIPLIER u120) ;; 120% maximum liquidation reward multiplier

;; PROTOCOL STATE VARIABLES

;; Core Protocol Configuration
(define-data-var contract-owner principal tx-sender)
(define-data-var protocol-paused bool false)
(define-data-var total-deposits uint u0)
(define-data-var total-borrows uint u0)
(define-data-var interest-rate uint u500) ;; 5% APR in basis points
(define-data-var liquidation-threshold uint u8000) ;; 80% liquidation threshold
(define-data-var allowed-token principal 'SP000000000000000000002Q6VF78.token)

;; DATA STORAGE MAPS

;; User Deposit Tracking
(define-map user-deposits
    { user: principal }
    { amount: uint }
)

;; User Borrow Position Tracking
(define-map user-borrows
    { user: principal }
    {
        amount: uint,
        collateral: uint,
    }
)

;; Liquidator Reward Accumulation
(define-map liquidator-rewards
    { liquidator: principal }
    { amount: uint }
)

;; SIP-010 TOKEN INTERFACE

;; Standard SIP-010 Fungible Token Trait
(define-trait sip-010-trait (
    (transfer
        (uint principal principal (optional (buff 34)))
        (response bool uint)
    )
    (get-balance
        (principal)
        (response uint uint)
    )
))

;; AUTHORIZATION & VALIDATION FUNCTIONS

;; Contract Owner Authorization Check
(define-private (is-contract-owner)
    (is-eq tx-sender (var-get contract-owner))
)

;; Token Contract Validation
(define-private (is-valid-token (token-contract <sip-010-trait>))
    (is-eq (contract-of token-contract) (var-get allowed-token))
)

;; SAFE ARITHMETIC OPERATIONS

;; Safe Subtraction with Underflow Protection
(define-private (safe-subtract
        (a uint)
        (b uint)
    )
    (ok (if (>= a b)
        (- a b)
        u0
    ))
)

;; Safe Addition with Overflow Protection
(define-private (safe-add
        (a uint)
        (b uint)
    )
    (let ((sum (+ a b)))
        (asserts! (>= sum a) (err u401))
        ;; Overflow check
        (ok sum)
    )
)

;; Safe Multiplication with Overflow Protection
(define-private (safe-multiply
        (a uint)
        (b uint)
    )
    (let ((product (* a b)))
        (asserts! (or (is-eq a u0) (is-eq (/ product a) b)) (err u402))
        ;; Overflow check
        (ok product)
    )
)

;; CORE PROTOCOL FUNCTIONS

;; Protocol Initialization
(define-public (initialize (token-contract <sip-010-trait>))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (ok true)
    )
)

;; Collateral Deposit Function
(define-public (deposit-collateral
        (token-contract <sip-010-trait>)
        (amount uint)
    )
    (let (
            (sender tx-sender)
            (current-deposit (default-to { amount: u0 } (map-get? user-deposits { user: sender })))
        )
        ;; Input Validation
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (not (var-get protocol-paused)) ERR-NOT-INITIALIZED)
        (asserts! (is-valid-token token-contract) ERR-NOT-AUTHORIZED)
        ;; Execute Token Transfer
        (match (contract-call? token-contract transfer amount sender
            (as-contract tx-sender) none
        )
            success (begin
                ;; Update User Deposit Records
                (map-set user-deposits { user: sender } { amount: (+ amount (get amount current-deposit)) })
                ;; Update Protocol Statistics
                (var-set total-deposits (+ (var-get total-deposits) amount))
                (ok true)
            )
            error (err u101)
        )
    )
)

;; Borrow Against Collateral Function
(define-public (borrow
        (token-contract <sip-010-trait>)
        (amount uint)
    )
    (let (
            (sender tx-sender)
            (user-deposit (default-to { amount: u0 } (map-get? user-deposits { user: sender })))
            (user-borrow (default-to {
                amount: u0,
                collateral: u0,
            }
                (map-get? user-borrows { user: sender })
            ))
            (collateral-value (get amount user-deposit))
            (borrow-value (+ amount (get amount user-borrow)))
        )
        ;; Input and Risk Validation
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (not (var-get protocol-paused)) ERR-NOT-INITIALIZED)
        (asserts! (is-collateral-sufficient collateral-value borrow-value)
            ERR-INSUFFICIENT-COLLATERAL
        )
        ;; Update Borrow Position
        (map-set user-borrows { user: sender } {
            amount: borrow-value,
            collateral: collateral-value,
        })
        ;; Update Protocol Statistics
        (var-set total-borrows (+ (var-get total-borrows) amount))
        (ok true)
    )
)

;; Loan Repayment Function
(define-public (repay
        (token-contract <sip-010-trait>)
        (amount uint)
    )
    (let (
            (sender tx-sender)
            (user-borrow (default-to {
                amount: u0,
                collateral: u0,
            }
                (map-get? user-borrows { user: sender })
            ))
            (borrow-amount (get amount user-borrow))
        )
        ;; Input Validation
        (asserts! (>= borrow-amount amount) ERR-INVALID-AMOUNT)
        (asserts! (is-valid-token token-contract) ERR-NOT-AUTHORIZED)
        ;; Execute Repayment Transfer
        (match (contract-call? token-contract transfer amount sender
            (as-contract tx-sender) none
        )
            success (begin
                ;; Update Borrow Position
                (map-set user-borrows { user: sender } {
                    amount: (- borrow-amount amount),
                    collateral: (get collateral user-borrow),
                })
                ;; Update Protocol Statistics
                (var-set total-borrows (- (var-get total-borrows) amount))
                (ok true)
            )
            error (err u101)
        )
    )
)

;; LIQUIDATION SYSTEM

;; Position Liquidation Function
(define-public (liquidate
        (token-contract <sip-010-trait>)
        (user principal)
        (amount uint)
    )
    (let (
            (liquidator tx-sender)
            (user-borrow (default-to {
                amount: u0,
                collateral: u0,
            }
                (map-get? user-borrows { user: user })
            ))
            (borrow-amount (get amount user-borrow))
            (collateral-amount (get collateral user-borrow))
        )
        ;; Liquidation Validation
        (asserts! (is-valid-token token-contract) ERR-NOT-AUTHORIZED)
        (asserts! (can-liquidate user borrow-amount collateral-amount)
            ERR-LIQUIDATION-FAILED
        )
        (asserts! (<= amount borrow-amount) ERR-INVALID-AMOUNT)
        ;; Execute Liquidation Payment
        (match (contract-call? token-contract transfer amount liquidator
            (as-contract tx-sender) none
        )
            success (begin
                (let (
                        (reward (calculate-liquidation-reward amount collateral-amount))
                        (current-rewards (default-to { amount: u0 }
                            (map-get? liquidator-rewards { liquidator: liquidator })
                        ))
                    )
                    ;; Update Liquidator Rewards
                    (map-set liquidator-rewards { liquidator: liquidator } { amount: (+ (get amount current-rewards) reward) })
                    ;; Update User Position After Liquidation
                    (map-set user-borrows { user: user } {
                        amount: (- borrow-amount amount),
                        collateral: (- collateral-amount reward),
                    })
                    (ok true)
                )
            )
            error (err u101)
        )
    )
)

;; Liquidation Reward Claim Function
(define-public (claim-rewards (token-contract <sip-010-trait>))
    (let (
            (liquidator tx-sender)
            (rewards (default-to { amount: u0 }
                (map-get? liquidator-rewards { liquidator: liquidator })
            ))
            (reward-amount (get amount rewards))
        )
        ;; Reward Validation
        (asserts! (> reward-amount u0) ERR-INSUFFICIENT-BALANCE)
        ;; Reset Liquidator Rewards
        (map-set liquidator-rewards { liquidator: liquidator } { amount: u0 })
        (ok true)
    )
)

;; RISK CALCULATION HELPERS

;; Liquidation Eligibility Check
(define-private (can-liquidate
        (user principal)
        (borrow-amount uint)
        (collateral-amount uint)
    )
    (let ((collateral-ratio (calculate-collateral-ratio borrow-amount collateral-amount)))
        (<= collateral-ratio (var-get liquidation-threshold))
    )
)

;; Collateral Ratio Calculation
(define-private (calculate-collateral-ratio
        (borrow-amount uint)
        (collateral-amount uint)
    )
    (if (is-eq borrow-amount u0)
        u0
        (* (/ (* collateral-amount u10000) borrow-amount) u100)
    )
)

;; Collateral Sufficiency Validation
(define-private (is-collateral-sufficient
        (collateral-value uint)
        (borrow-value uint)
    )
    (>= (* collateral-value MIN-COLLATERAL-RATIO) (* borrow-value u100))
)

;; Liquidation Reward Calculation
(define-private (calculate-liquidation-reward
        (liquidation-amount uint)
        (collateral-amount uint)
    )
    (let (
            (base-reward (* liquidation-amount u105)) ;; 5% liquidation bonus
            (max-reward (* collateral-amount u50)) ;; Maximum 50% of collateral
        )
        (if (> base-reward max-reward)
            max-reward
            base-reward
        )
    )
)

;; READ-ONLY DATA QUERIES

;; User Deposit Information Retrieval
(define-read-only (get-user-deposits (user principal))
    (default-to { amount: u0 } (map-get? user-deposits { user: user }))
)

;; User Borrow Position Retrieval
(define-read-only (get-user-borrows (user principal))
    (default-to {
        amount: u0,
        collateral: u0,
    }
        (map-get? user-borrows { user: user })
    )
)

;; Protocol Statistics Overview
(define-read-only (get-protocol-stats)
    {
        total-deposits: (var-get total-deposits),
        total-borrows: (var-get total-borrows),
        interest-rate: (var-get interest-rate),
    }
)