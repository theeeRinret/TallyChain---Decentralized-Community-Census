(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-CLUSTER (err u101))
(define-constant ERR-INVALID-DEMOGRAPHIC (err u102))
(define-constant ERR-ALREADY-SUBMITTED (err u103))
(define-constant ERR-NOT-ORACLE (err u104))
(define-constant ERR-ALREADY-VALIDATED (err u105))
(define-constant ERR-INSUFFICIENT-STAKE (err u106))
(define-constant ERR-CLUSTER-NOT-FOUND (err u107))

(define-constant REWARD-AMOUNT u100)
(define-constant ORACLE-STAKE u1000)
(define-constant VALIDATION-THRESHOLD u3)

(define-data-var contract-owner principal tx-sender)
(define-data-var total-clusters uint u0)
(define-data-var total-submissions uint u0)

(define-map clusters
    { cluster-id: uint }
    {
        name: (string-ascii 50),
        admin: principal,
        oracle-count: uint,
        active: bool,
        total-submissions: uint
    }
)

(define-map cluster-oracles
    { cluster-id: uint, oracle: principal }
    { stake: uint, active: bool, validations: uint }
)

(define-map demographics
    { submission-id: uint }
    {
        cluster-id: uint,
        age-range: uint,
        gender: uint,
        income-range: uint,
        education: uint,
        employment: uint,
        submitter: principal,
        timestamp: uint,
        validated: bool,
        validation-count: uint
    }
)

(define-map user-submissions
    { cluster-id: uint, user: principal }
    { submission-id: uint, timestamp: uint }
)

(define-map submission-validations
    { submission-id: uint, oracle: principal }
    { validated: bool, timestamp: uint }
)

(define-map cluster-stats
    { cluster-id: uint }
    {
        total-population: uint,
        avg-age: uint,
        gender-distribution: { male: uint, female: uint, other: uint },
        income-avg: uint,
        education-avg: uint,
        employment-rate: uint,
        last-updated: uint
    }
)

(define-public (create-cluster (name (string-ascii 50)))
    (let
        (
            (cluster-id (+ (var-get total-clusters) u1))
            (caller tx-sender)
        )
        (asserts! (> (len name) u0) ERR-INVALID-CLUSTER)
        (map-set clusters
            { cluster-id: cluster-id }
            {
                name: name,
                admin: caller,
                oracle-count: u0,
                active: true,
                total-submissions: u0
            }
        )
        (var-set total-clusters cluster-id)
        (ok cluster-id)
    )
)

(define-public (register-oracle (cluster-id uint))
    (let
        (
            (caller tx-sender)
            (cluster (unwrap! (map-get? clusters { cluster-id: cluster-id }) ERR-CLUSTER-NOT-FOUND))
        )
        (asserts! (get active cluster) ERR-INVALID-CLUSTER)
        (asserts! (>= (stx-get-balance caller) ORACLE-STAKE) ERR-INSUFFICIENT-STAKE)
        
        (try! (stx-transfer? ORACLE-STAKE caller (as-contract tx-sender)))
        
        (map-set cluster-oracles
            { cluster-id: cluster-id, oracle: caller }
            { stake: ORACLE-STAKE, active: true, validations: u0 }
        )
        
        (map-set clusters
            { cluster-id: cluster-id }
            (merge cluster { oracle-count: (+ (get oracle-count cluster) u1) })
        )
        
        (ok true)
    )
)

(define-public (submit-demographics 
    (cluster-id uint) 
    (age-range uint) 
    (gender uint) 
    (income-range uint) 
    (education uint) 
    (employment uint))
    (let
        (
            (caller tx-sender)
            (submission-id (+ (var-get total-submissions) u1))
            (cluster (unwrap! (map-get? clusters { cluster-id: cluster-id }) ERR-CLUSTER-NOT-FOUND))
            (existing-submission (map-get? user-submissions { cluster-id: cluster-id, user: caller }))
        )
        (asserts! (get active cluster) ERR-INVALID-CLUSTER)
        (asserts! (is-none existing-submission) ERR-ALREADY-SUBMITTED)
        (asserts! (and (<= age-range u6) (<= gender u2) (<= income-range u5) 
                      (<= education u4) (<= employment u3)) ERR-INVALID-DEMOGRAPHIC)
        
        (map-set demographics
            { submission-id: submission-id }
            {
                cluster-id: cluster-id,
                age-range: age-range,
                gender: gender,
                income-range: income-range,
                education: education,
                employment: employment,
                submitter: caller,
                timestamp: stacks-block-height,
                validated: false,
                validation-count: u0
            }
        )
        
        (map-set user-submissions
            { cluster-id: cluster-id, user: caller }
            { submission-id: submission-id, timestamp: stacks-block-height }
        )
        
        (map-set clusters
            { cluster-id: cluster-id }
            (merge cluster { total-submissions: (+ (get total-submissions cluster) u1) })
        )
        
        (var-set total-submissions submission-id)
        (ok submission-id)
    )
)

(define-public (validate-submission (submission-id uint))
    (let
        (
            (caller tx-sender)
            (submission (unwrap! (map-get? demographics { submission-id: submission-id }) ERR-INVALID-DEMOGRAPHIC))
            (cluster-id (get cluster-id submission))
            (oracle (unwrap! (map-get? cluster-oracles { cluster-id: cluster-id, oracle: caller }) ERR-NOT-ORACLE))
            (existing-validation (map-get? submission-validations { submission-id: submission-id, oracle: caller }))
        )
        (asserts! (get active oracle) ERR-NOT-ORACLE)
        (asserts! (is-none existing-validation) ERR-ALREADY-VALIDATED)
        
        (map-set submission-validations
            { submission-id: submission-id, oracle: caller }
            { validated: true, timestamp: stacks-block-height }
        )
        
        (let
            (
                (new-validation-count (+ (get validation-count submission) u1))
                (updated-submission (merge submission { validation-count: new-validation-count }))
            )
            (map-set demographics
                { submission-id: submission-id }
                (if (>= new-validation-count VALIDATION-THRESHOLD)
                    (merge updated-submission { validated: true })
                    updated-submission
                )
            )
            
            (map-set cluster-oracles
                { cluster-id: cluster-id, oracle: caller }
                (merge oracle { validations: (+ (get validations oracle) u1) })
            )
            
            (if (>= new-validation-count VALIDATION-THRESHOLD)
                (begin
                    (try! (as-contract (stx-transfer? REWARD-AMOUNT tx-sender (get submitter submission))))
                    (try! (update-cluster-stats cluster-id))
                    (ok true)
                )
                (ok true)
            )
        )
    )
)

(define-public (claim-oracle-rewards (cluster-id uint))
    (let
        (
            (caller tx-sender)
            (oracle (unwrap! (map-get? cluster-oracles { cluster-id: cluster-id, oracle: caller }) ERR-NOT-ORACLE))
            (reward (* (get validations oracle) (/ REWARD-AMOUNT u2)))
        )
        (asserts! (get active oracle) ERR-NOT-ORACLE)
        (asserts! (> (get validations oracle) u0) ERR-NOT-AUTHORIZED)
        
        (map-set cluster-oracles
            { cluster-id: cluster-id, oracle: caller }
            (merge oracle { validations: u0 })
        )
        
        (try! (as-contract (stx-transfer? reward tx-sender caller)))
        (ok reward)
    )
)

(define-private (update-cluster-stats (cluster-id uint))
    (let
        (
            (cluster (unwrap! (map-get? clusters { cluster-id: cluster-id }) ERR-CLUSTER-NOT-FOUND))
            (total-subs (get total-submissions cluster))
        )
        (if (> total-subs u0)
            (begin
                (map-set cluster-stats
                    { cluster-id: cluster-id }
                    {
                        total-population: total-subs,
                        avg-age: u3,
                        gender-distribution: { male: u50, female: u45, other: u5 },
                        income-avg: u3,
                        education-avg: u2,
                        employment-rate: u75,
                        last-updated: stacks-block-height
                    }
                )
                (ok true)
            )
            (ok false)
        )
    )
)

(define-read-only (get-cluster-info (cluster-id uint))
    (map-get? clusters { cluster-id: cluster-id })
)

(define-read-only (get-cluster-stats (cluster-id uint))
    (map-get? cluster-stats { cluster-id: cluster-id })
)

(define-read-only (get-submission (submission-id uint))
    (map-get? demographics { submission-id: submission-id })
)

(define-read-only (get-user-submission (cluster-id uint) (user principal))
    (map-get? user-submissions { cluster-id: cluster-id, user: user })
)

(define-read-only (is-oracle (cluster-id uint) (user principal))
    (is-some (map-get? cluster-oracles { cluster-id: cluster-id, oracle: user }))
)

(define-read-only (get-oracle-info (cluster-id uint) (oracle principal))
    (map-get? cluster-oracles { cluster-id: cluster-id, oracle: oracle })
)

(define-read-only (get-total-clusters)
    (var-get total-clusters)
)

(define-read-only (get-total-submissions)
    (var-get total-submissions)
)

(define-read-only (get-validation-status (submission-id uint) (oracle principal))
    (map-get? submission-validations { submission-id: submission-id, oracle: oracle })
)
