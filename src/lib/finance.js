export function positionValue(quantity, price) {
  if (![quantity, price].every(Number.isFinite) || quantity < 0 || price < 0) throw new RangeError('Quantity and price must be non-negative finite numbers')
  return quantity * price
}

export function portfolioValue(cash, positions) {
  if (!Number.isFinite(cash) || cash < 0 || !Array.isArray(positions)) throw new RangeError('Invalid portfolio')
  return cash + positions.reduce((sum, position) => sum + positionValue(position.quantity, position.price), 0)
}

// Average cost: purchase fees are added to basis; sale fees are deducted from proceeds.
export function realizeSale({ quantity, salePrice, averageCost, feeRate = 0.001 }) {
  if (![quantity, salePrice, averageCost, feeRate].every(Number.isFinite) || quantity <= 0 || salePrice <= 0 || averageCost < 0 || feeRate < 0) throw new RangeError('Invalid sale inputs')
  const gross = quantity * salePrice
  const fee = gross * feeRate
  return { gross, fee, realizedPnl: gross - fee - quantity * averageCost }
}
