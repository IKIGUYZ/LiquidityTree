// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

contract LiquidityTree {
    struct Node {
        uint64 actionNumber; // last update number
        uint128 amount; // node amount
    }

    uint40 constant DECIMALS = 10**12;
    uint48 immutable LIQUIDITYNODES; // = 1_099_511_627_776; // begining of data nodes (top at node #1)
    uint48 immutable LIQUIDITYLASTNODE; // LIQUIDITYNODES * 2 - 1

    uint48 public nextNode; // next unused node number for adding liquidity

    uint64 public actionNumber; // action number, used instead of timestamp for splitting changes time on the same nodes

    // liquidity (segment) tree
    mapping(uint48 => Node) public treeNode;

    event withdrawn(address wallet, uint128 amount);

    error LeafNotExist();
    error IncorrectPercent();

    /**
     * @dev initializing LIQUIDITYNODES and nextNode. 
     * @dev LIQUIDITYNODES is count of liquidity (segment) tree leaves contains single liquidity addings
     * @dev liquidity (segment) tree build as array of 2*LIQUIDITYNODES count, top node has id #1 (id #0 not used)
     * @dev liquidity (segment) tree leaves is array [LIQUIDITYNODES, 2*LIQUIDITYNODES-1]
     * @dev liquidity (segment) tree node index N has left child index 2*N and right child index 2N+1
     * @dev +--------------------------------------------+
            |                  1 (top node)              |
            +------------------------+-------------------+
            |             2          |         3         |
            +-------------+----------+---------+---------+
            | 4 (nextNode)|     5    |    6    |    7    |
            +-------------+----------+---------+---------+
     * @param liquidityNodes count of leaves - possible single liquidity addings
     */
    constructor(uint48 liquidityNodes) {
        LIQUIDITYNODES = liquidityNodes;
        LIQUIDITYLASTNODE = liquidityNodes * 2 - 1;
        nextNode = liquidityNodes;
        actionNumber++; // start from non zero
    }

    /**
     * @dev add liquidity amount from the leaf up to top node
     * @param amount - adding amount
     */
    function nodeAddLiquidity(uint128 amount) public returns (uint48 resNode) {
        updateUp(nextNode, amount, false, ++actionNumber);
        resNode = nextNode;
        nextNode++;
    }

    /**
     * @dev withdraw all liquidity from the leaf, due possible many changes in leafe's parent nodes
     * @dev it is needed firstly to update its amount and then withdraw
     * @dev used steps:
     * @dev 1 - get last updated parent most near to the leaf
     * @dev 2 - push all changes from found parent doen to the leaf - that updates leaf's amount
     * @dev 3 - execute withdraw of leaf amount and update amount changing up to top parents
     * @param leaf - leaf number to completely withdraw
     */
    function nodeWithdraw(uint48 leaf) public returns (uint128 withdrawAmount) {
        withdrawAmount = nodeWithdrawPercent(leaf, DECIMALS);
    }

    /**
     * @dev withdraw part of liquidity from the leaf, due possible many changes in leafe's parent nodes
     * @dev it is needed firstly to update its amount and then withdraw
     * @dev used steps:
     * @dev 1 - get last updated parent most near to the leaf
     * @dev 2 - push all changes from found parent doen to the leaf - that updates leaf's amount
     * @dev 3 - execute withdraw of leaf amount and update amount changing up to top parents
     * @param leaf -
     * @param percent - percent of leaf amount 1*10^12 is 100%, 5*10^11 is 50%
     */
    function nodeWithdrawPercent(uint48 leaf, uint40 percent)
        public
        returns (uint128 withdrawAmount)
    {
        if (treeNode[leaf].actionNumber == 0) revert LeafNotExist();
        if (percent > DECIMALS) revert IncorrectPercent();

        // get last-updated top node
        (uint48 updatedNode, uint48 begin, uint48 end) = getUpdatedNode(
            1,
            treeNode[1].actionNumber,
            LIQUIDITYNODES,
            LIQUIDITYLASTNODE,
            1,
            LIQUIDITYNODES,
            LIQUIDITYLASTNODE,
            leaf
        );
        // push changes from last-updated node down to the leaf, if leaf is not up to date
        push(updatedNode, begin, end, leaf, ++actionNumber);

        // remove amount (percent of amount) from leaf to it's parents
        withdrawAmount = (treeNode[leaf].amount * percent) / DECIMALS;

        updateUp(leaf, withdrawAmount, true, ++actionNumber);

        emit withdrawn(msg.sender, withdrawAmount);
    }

    /**
     * @dev top node is ever most updated, trying to find lower node not older then top node
     * @dev get nearest to leaf (lowest) last-updated node from the parents, runing down from top to leaf
     * @param parent top node
     * @param parentTimestamp top node timestamp
     * @param parentBegin top node most left leaf
     * @param parentEnd top node most right leaf
     * @param node node parent for the leaf
     * @param begin node most left leaf
     * @param end node most right leaf
     * @param leaf target leaf
     * @return resParent found most updated leaf parent
     * @return resBegin found parent most left leaf
     * @return resEnd found parent most right leaf
     */
    function getUpdatedNode(
        uint48 parent,
        uint64 parentTimestamp,
        uint48 parentBegin,
        uint48 parentEnd,
        uint48 node,
        uint48 begin,
        uint48 end,
        uint48 leaf
    )
        internal
        view
        returns (
            uint48 resParent,
            uint48 resBegin,
            uint48 resEnd
        )
    {
        // if node is older than it's parent, stop and return parent
        if (treeNode[node].actionNumber < parentTimestamp) {
            return (parent, parentBegin, parentEnd);
        }
        if (node == leaf) {
            return (leaf, begin, end);
        }

        uint48 mid = (begin + end) / 2;

        if (begin <= leaf && leaf <= mid) {
            // work on left child
            (resParent, resBegin, resEnd) = getUpdatedNode(
                node,
                parentTimestamp,
                begin,
                end,
                node * 2,
                begin,
                mid,
                leaf
            );
        } else {
            // work on right child
            (resParent, resBegin, resEnd) = getUpdatedNode(
                node,
                parentTimestamp,
                begin,
                end,
                node * 2 + 1,
                mid + 1,
                end,
                leaf
            );
        }
    }

    /**
     * @dev update up amounts from leaf up to top node #1, used in adding/removing values on leaves
     * @param child node for update
     * @param amount value for update
     * @param isSub true - reduce, false - add
     * @param action action number
     */
    function updateUp(
        uint48 child,
        uint128 amount,
        bool isSub,
        uint64 action
    ) internal {
        changeAmount(child, amount, isSub, action);
        // if not top parent
        if (child != 1) {
            updateUp(getParent(child), amount, isSub, action);
        }
    }

    /**
     * @dev add amount to whole tree, starting from top node #1
     * @param amount value to add
     */
    function add(uint128 amount) public {
        pushLazy(
            1,
            LIQUIDITYNODES,
            LIQUIDITYLASTNODE,
            LIQUIDITYNODES,
            nextNode - 1,
            amount,
            false,
            ++actionNumber
        );
    }

    /**
     * @dev add amount only for limited leaves in tree [first_leaf, leaf]
     * @param amount value to add
     */
    function addLimit(uint128 amount, uint48 leaf) public {
        // get last-updated top node
        (uint48 updatedNode, uint48 begin, uint48 end) = getUpdatedNode(
            1,
            treeNode[1].actionNumber,
            LIQUIDITYNODES,
            LIQUIDITYLASTNODE,
            1,
            LIQUIDITYNODES,
            LIQUIDITYLASTNODE,
            leaf
        );

        // push changes from last-updated node down to the leaf, if leaf is not up to date
        push(updatedNode, begin, end, leaf, ++actionNumber);

        pushLazy(
            1,
            LIQUIDITYNODES,
            LIQUIDITYLASTNODE,
            LIQUIDITYNODES,
            leaf,
            amount,
            false,
            ++actionNumber
        );
    }

    /**
     * @dev remove amount only for limited leaves in tree [first_leaf, leaf]
     * @param amount value to remove
     */
    function removeLimit(uint128 amount, uint48 leaf) public {
        if (treeNode[1].amount >= amount) {
            // get last-updated top node
            (uint48 updatedNode, uint48 begin, uint48 end) = getUpdatedNode(
                1,
                treeNode[1].actionNumber,
                LIQUIDITYNODES,
                LIQUIDITYLASTNODE,
                1,
                LIQUIDITYNODES,
                LIQUIDITYLASTNODE,
                leaf
            );

            // push changes from last-updated node down to the leaf, if leaf is not up to date
            push(updatedNode, begin, end, leaf, ++actionNumber);

            pushLazy(
                1,
                LIQUIDITYNODES,
                LIQUIDITYLASTNODE,
                LIQUIDITYNODES,
                leaf,
                amount,
                true,
                ++actionNumber
            );
        }
    }

    /**
     * @dev remove amount from whole tree, starting from top node #1
     * @param amount value to remove
     */
    function remove(uint128 amount) public {
        if (treeNode[1].amount >= amount) {
            pushLazy(
                1,
                LIQUIDITYNODES,
                LIQUIDITYLASTNODE,
                LIQUIDITYNODES,
                nextNode - 1,
                amount,
                true,
                ++actionNumber
            );
        }
    }

    /**
     * @dev push changes from last "lazy update" down to leaf
     * @param node - last node from lazy update
     * @param begin - leaf search start
     * @param end - leaf search end
     * @param leaf - last node to update
     * @param action action number
     */
    function push(
        uint48 node,
        uint48 begin,
        uint48 end,
        uint48 leaf,
        uint64 action
    ) internal {
        // if node is leaf, stop
        if (node == leaf) {
            return;
        }
        uint48 lChild = node * 2;
        uint48 rChild = node * 2 + 1;
        uint128 amount = treeNode[node].amount;
        uint256 lAmount = treeNode[lChild].amount;
        uint256 rAmount = treeNode[rChild].amount;
        uint256 sumAmounts = lAmount + rAmount;
        if (sumAmounts == 0) return;
        uint128 setLAmount = uint128((amount * lAmount) / sumAmounts);

        // update left and right child
        setAmount(lChild, setLAmount, action);
        setAmount(rChild, amount - setLAmount, action);

        uint48 mid = (begin + end) / 2;

        if (begin <= leaf && leaf <= mid) {
            push(lChild, begin, mid, leaf, action);
        } else {
            push(rChild, mid + 1, end, leaf, action);
        }
    }

    /**
     * @dev push lazy (lazy propagation) amount value from top node to child nodes contained leafs from 0 to r
     * @param node - start from node
     * @param begin - node left element
     * @param end - node right element
     * @param l - left leaf child
     * @param r - right leaf child
     * @param amount - amount to add/reduce stored amounts
     * @param isSub - true means negative to reduce
     * @param action action number
     */
    function pushLazy(
        uint48 node,
        uint48 begin,
        uint48 end,
        uint48 l,
        uint48 r,
        uint128 amount,
        bool isSub,
        uint64 action
    ) internal {
        if ((begin == l && end == r) || (begin == end)) {
            // if node leafs equal to leaf interval then stop
            changeAmount(node, amount, isSub, action);
            return;
        }

        uint48 mid = (begin + end) / 2;

        if (begin <= l && l <= mid) {
            if (begin <= r && r <= mid) {
                // [l,r] in [begin,mid] - all leafs in left child
                pushLazy(node * 2, begin, mid, l, r, amount, isSub, action);
            } else {
                uint128 lAmount = treeNode[node * 2].amount;
                // get right amount excluding unused leaves when adding amounts
                uint128 rAmount = treeNode[node * 2 + 1].amount -
                    (
                        !isSub
                            ? getLeavesAmount(
                                node * 2 + 1,
                                mid + 1,
                                end,
                                r + 1,
                                end
                            )
                            : 0
                    );
                uint128 sumAmounts = lAmount + rAmount;
                if (sumAmounts == 0) return;
                uint128 forLeftAmount = (amount *
                    ((lAmount * DECIMALS) / sumAmounts)) / DECIMALS;

                // l in [begin,mid] - part in left child
                pushLazy(
                    node * 2,
                    begin,
                    mid,
                    l,
                    mid,
                    forLeftAmount,
                    isSub,
                    action
                );

                // r in [mid+1,end] - part in right child
                pushLazy(
                    node * 2 + 1,
                    mid + 1,
                    end,
                    mid + 1,
                    r,
                    amount - forLeftAmount,
                    isSub,
                    action
                );
            }
        } else {
            // [l,r] in [mid+1,end] - all leafs in right child
            pushLazy(node * 2 + 1, mid + 1, end, l, r, amount, isSub, action);
        }
        changeAmount(node, amount, isSub, action);
    }

    /**
     * @dev change amount by adding value or reducing value
     * @param node - node for changing
     * @param amount - amount value for changing
     * @param isSub - true - reduce by amount, true - add by amount
     * @param action - action number
     */
    function changeAmount(
        uint48 node,
        uint128 amount,
        bool isSub,
        uint64 action
    ) internal {
        treeNode[node].actionNumber = action;
        if (isSub) {
            treeNode[node].amount -= amount;
        } else {
            treeNode[node].amount += amount;
        }
    }

    /**
     * @dev reset node amount, used in push
     * @param node for set
     * @param amount value
     * @param action action number
     */
    function setAmount(
        uint48 node,
        uint128 amount,
        uint64 action
    ) internal {
        if (treeNode[node].amount != amount) {
            treeNode[node].actionNumber = action;
            treeNode[node].amount = amount;
        }
    }

    /**
     * @dev parent N has left child 2N and right child 2N+1getLeavesAmount
     * @param fromNumber - get parent from some child
     * @return parentNumber - found parent
     */
    function getParent(uint48 fromNumber)
        public
        pure
        returns (uint48 parentNumber)
    {
        // if requested from top
        if (fromNumber == 1) {
            return 1;
        }
        return fromNumber / 2;
    }

    /**
     * @dev for current node get sum amount of exact leaves list
     * @param node node to get sum amount
     * @param begin - node left element
     * @param end - node right element
     * @param l - left leaf of the list
     * @param r - right leaf of the list
     * @return amount sum of leaves list
     */
    function getLeavesAmount(
        uint48 node,
        uint48 begin,
        uint48 end,
        uint48 l,
        uint48 r
    ) public view returns (uint128 amount) {
        if ((begin == l && end == r) || (begin == end)) {
            // if node leafs equal to leaf interval then stop and return amount value
            return (treeNode[node].amount);
        }

        uint48 mid = (begin + end) / 2;

        if (begin <= l && l <= mid) {
            if (begin <= r && r <= mid) {
                amount += getLeavesAmount(node * 2, begin, mid, l, r);
            } else {
                amount += getLeavesAmount(node * 2, begin, mid, l, mid);
                amount += getLeavesAmount(
                    node * 2 + 1,
                    mid + 1,
                    end,
                    mid + 1,
                    r
                );
            }
        } else {
            amount += getLeavesAmount(node * 2 + 1, mid + 1, end, l, r);
        }

        return amount;
    }
}
