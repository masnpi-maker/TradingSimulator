import { describe, expect, it } from 'vitest'
import { portfolioValue, positionValue, realizeSale } from './finance.js'

describe('financial calculations', () => {
  it('values a position and portfolio from cash plus holdings', () => {
    expect(positionValue(2.5, 100)).toBe(250)
    expect(portfolioValue(500, [{ quantity: 2, price: 25 }, { quantity: 1, price: 10 }])).toBe(560)
  })
  it('computes realized P/L using average cost and sale fees', () => {
    expect(realizeSale({ quantity: 4, salePrice: 20, averageCost: 15 })).toEqual({ gross: 80, fee: 0.08, realizedPnl: 19.92 })
  })
  it('rejects negative or non-finite inputs', () => {
    expect(() => positionValue(-1, 10)).toThrow(RangeError)
    expect(() => portfolioValue(-1, [])).toThrow(RangeError)
    expect(() => realizeSale({ quantity: 0, salePrice: 10, averageCost: 1 })).toThrow(RangeError)
  })
})
